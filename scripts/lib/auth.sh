# shellcheck shell=sh
# lib/auth.sh -- sessions: login, storage-state, preflight
#
# Sourced by scripts/tf.sh; defines functions only. See tf.sh for the paths
# and schema variables these rely on.

# =================================================================== execution

# preflight [--warn-only] -- is the app up, and is every role really logged in?
#
# Fails fast so a dead app, or a dead session, costs a few requests instead of a
# whole suite of failures. A session file existing proves nothing: sessions
# expire, and a run with an expired one looks logged out to every case -- so
# every permission case "passes". Each role is therefore checked by sending a
# real request with its session to a page only a logged-in user can open.
#
# A dead role with credentials is logged in again once, automatically. Anything
# still dead -- or a probe page that cannot tell logged-in from logged-out --
# exits 3, unless --warn-only.
cmd_preflight() {
  warn_only=0; [ "${1:-}" = "--warn-only" ] && warn_only=1
  assert_target_allowed
  base="$(json_get "$CREDS" base_url)"
  have curl || die3 "preflight: curl not found"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$base" 2>/dev/null)"; [ -n "$code" ] || code=000
  case "$code" in
    000) die3 "preflight: $base is unreachable. Start the app first." ;;
    5*)  die3 "preflight: $base returned $code. The app is up but erroring." ;;
  esac
  echo "preflight: $base -> $code"

  mkdir -p "$CACHE"
  bad=""
  for role in $(json_keys "$CREDS" roles 2>/dev/null); do
    case "$role" in anonymous|nobody) continue ;; esac
    _pf_role "$role" || bad="$bad $role"
  done
  rm -f "$CACHE"/.pf-*."$$"

  [ -z "$bad" ] && return 0
  if [ "$warn_only" = 1 ]; then
    echo "preflight: not ready:$bad (--warn-only, continuing)" >&2
    return 0
  fi
  die3 "preflight: no working session for:$bad
    Cases for these roles would run logged out and prove nothing. Log them in
    (the login-broker agent, or /test-setup), then run preflight again."
}

# The page a role's session is proved against: the role's own probe, the
# suite's, or the page login already treats as proof of success.
_pf_probe_path() {
  p="$(json_get "$CREDS" "roles.$1.probe" 2>/dev/null)"
  [ -n "$p" ] || p="$(json_get "$CREDS" login.session_probe 2>/dev/null)"
  [ -n "$p" ] || p="$(json_get "$CREDS" login.success_indicator 2>/dev/null)"
  [ -n "$p" ] || p=/
  printf '%s' "$p"
}

# _pf_role <role> -- check, recover once, report. Returns 1 if not usable.
_pf_role() {
  r="$1"; jar="$TESTS_DIR/.auth/$r.cookies"; state="$TESTS_DIR/.auth/$r.json"
  probe="$(_pf_probe_path "$r")"

  # A browser session made from the jar is free; make it before judging.
  if [ -f "$jar" ] && [ ! -f "$state" ]; then
    cmd_storage_state "$r" >/dev/null 2>&1 || :
  fi

  verdict="$(_pf_check "$r" "$probe")"
  case "$verdict" in
    alive*)
      echo "preflight: $r alive (${verdict#alive })"; return 0 ;;
    unverifiable*)
      echo "preflight: $r UNVERIFIABLE -- $probe looks the same logged out. Set login.session_probe (or roles.$r.probe) in $CREDS to a page that needs a login." >&2
      return 1 ;;
  esac

  user="$(json_get "$CREDS" "roles.$r.username" 2>/dev/null)"
  pass="$(json_get "$CREDS" "roles.$r.password" 2>/dev/null)"
  if [ -z "$user" ] || [ -z "$pass" ]; then
    echo "preflight: $r DEAD (${verdict#dead: }) -- no credentials to log in again" >&2
    return 1
  fi
  echo "preflight: $r DEAD (${verdict#dead: }) -- logging in again" >&2
  if ( cmd_login "$r" ) >/dev/null 2>&1 && ( cmd_storage_state "$r" ) >/dev/null 2>&1; then
    again="$(_pf_check "$r" "$probe")"
    case "$again" in
      alive*) echo "preflight: $r alive after re-login (${again#alive })"; return 0 ;;
      unverifiable*) echo "preflight: $r logged in again, but $probe looks the same logged out -- set login.session_probe" >&2; return 1 ;;
    esac
    echo "preflight: $r still DEAD after re-login (${again#dead: })" >&2
  else
    echo "preflight: $r re-login failed -- the app likely needs a browser login (2FA, SSO, JS); use the login-broker agent" >&2
  fi
  return 1
}

# _pf_check <role> <probe> -- one line: "alive ...", "dead: ..." or
# "unverifiable". Every session artifact the role has is checked, because the
# API pass reads the jar and the browser pass reads the storage state: either
# one dead is a run that is half logged out.
_pf_check() {
  r="$1"; probe="$2"; jar="$TESTS_DIR/.auth/$r.cookies"; state="$TESTS_DIR/.auth/$r.json"
  if [ ! -f "$jar" ] && [ ! -f "$state" ]; then
    echo "dead: no session files"; return
  fi

  jar_cookie=""; state_cookie=""
  [ -f "$jar" ] && jar_cookie="$(_pf_jar_cookie "$jar")"
  [ -f "$state" ] && state_cookie="$(_pf_state_cookie "$state")"
  if [ -f "$jar" ] && [ -z "$jar_cookie" ]; then echo "dead: $(_pf_expiry "$jar" jar)"; return; fi
  if [ -f "$state" ] && [ -z "$state_cookie" ]; then echo "dead: $(_pf_expiry "$state" state)"; return; fi

  anon="$(_pf_anon "$probe")"
  set -- $anon; acode="$1"; asize="$2"; aform="$3"
  out=""
  for which in jar state; do
    if [ "$which" = jar ]; then c="$jar_cookie"; else c="$state_cookie"; fi
    [ -n "$c" ] || continue
    # The storage state made from this jar carries the same cookies: same answer.
    [ "$which" = state ] && [ "$c" = "$jar_cookie" ] && continue
    set -- $(_pf_request "$probe" "$c"); rcode="$1"; size="$2"; form="$3"
    case "$rcode" in
      2*) [ "$form" = login ] && { echo "dead: $which gets a login form at $probe ($rcode)"; return; } ;;
      30*) echo "dead: $which is redirected away from $probe ($rcode)"; return ;;
      *)  echo "dead: $which gets $rcode at $probe"; return ;;
    esac
    # Logged in and logged out look alike: this page proves nothing.
    case "$acode" in
      2*) if [ "$aform" != login ] && _pf_similar "$size" "$asize"; then echo "unverifiable"; return; fi ;;
    esac
    out="${out:+$out, }$which $rcode"
  done
  echo "alive probe $probe: $out"
}

# _pf_request <path> [cookie-header] -> "<code> <bytes> <login|page>"
_pf_request() {
  body="$CACHE/.pf-body.$$"
  if [ -n "${2:-}" ]; then
    code="$(curl -s -o "$body" -w '%{http_code}' --max-time 15 --max-redirs 0 \
             -H "Cookie: $2" "$base$1" 2>/dev/null)"
  else
    code="$(curl -s -o "$body" -w '%{http_code}' --max-time 15 --max-redirs 0 "$base$1" 2>/dev/null)"
  fi
  [ -n "$code" ] || code=000
  bytes="$(wc -c < "$body" 2>/dev/null | tr -d ' ')"; [ -n "$bytes" ] || bytes=0
  kind=page
  grep -qiE 'type=["'"'"']?password' "$body" 2>/dev/null && kind=login
  rm -f "$body"
  echo "$code $bytes $kind"
}

# One anonymous request per probe page, however many roles share it.
_pf_anon() {
  key="$CACHE/.pf-anon-$(printf '%s' "$1" | cksum | cut -d' ' -f1).$$"
  [ -f "$key" ] || _pf_request "$1" > "$key"
  cat "$key"
}

# Within 2% of each other: the same page, give or take a token or a timestamp.
_pf_similar() {
  [ "$1" -gt 0 ] && [ "$2" -gt 0 ] || return 1
  d=$(( $1 - $2 )); [ "$d" -lt 0 ] && d=$(( 0 - d ))
  [ $(( d * 50 )) -le "$1" ]
}

# Cookie header from a Netscape jar, leaving out anything already expired.
_pf_jar_cookie() {
  awk -v now="$(date +%s)" '
    { sub(/\r$/, ""); sub(/^#HttpOnly_/, "") }
    /^#/ || NF < 7 { next }
    $5 != 0 && $5 < now { next }
    { out = out (out == "" ? "" : "; ") $6 "=" $7 }
    END { print out }' "$1"
}

# Cookie header from a Playwright storage state. Handles both the
# one-cookie-per-line shape storage-state writes and a pretty-printed export.
_pf_state_cookie() {
  awk -v now="$(date +%s)" '
    { doc = doc $0 " " }
    function field(obj, k,   m) {
      if (match(obj, "\"" k "\"[ \t]*:[ \t]*\"[^\"]*\"")) {
        m = substr(obj, RSTART, RLENGTH); sub(/^[^:]*:[ \t]*"/, "", m); sub(/"$/, "", m); return m
      }
      if (match(obj, "\"" k "\"[ \t]*:[ \t]*-?[0-9.]+")) {
        m = substr(obj, RSTART, RLENGTH); sub(/^[^:]*:[ \t]*/, "", m); return m
      }
      return ""
    }
    END {
      i = index(doc, "\"cookies\""); if (!i) exit
      rest = substr(doc, i)
      j = index(rest, "\"origins\""); if (j) rest = substr(rest, 1, j)
      while (match(rest, /\{[^{}]*\}/)) {
        obj = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
        if (index(obj, "\"name\"") == 0) continue
        e = field(obj, "expires") + 0
        if (e > 0 && e < now) continue
        out = out (out == "" ? "" : "; ") field(obj, "name") "=" field(obj, "value")
      }
      print out
    }' "$1"
}

# Why a session file has no usable cookie: how long ago the newest one expired.
_pf_expiry() {
  if [ "$2" = jar ]; then
    newest="$(awk '{ sub(/^#HttpOnly_/, "") } /^#/ || NF < 7 { next } $5 > m { m = $5 } END { print m + 0 }' "$1")"
  else
    newest="$(grep -oE '"expires"[[:space:]]*:[[:space:]]*[0-9]+' "$1" | sed -E 's/.*:[[:space:]]*//' | sort -n | tail -1)"
  fi
  case "${newest:-0}" in
    0) echo "$2 has no cookies" ;;
    *) ago=$(( $(date +%s) - newest ))
       if [ "$ago" -ge 86400 ]; then echo "$2 cookies expired $(( ago / 86400 ))d ago"
       else echo "$2 cookies expired $(( ago / 3600 ))h ago"; fi ;;
  esac
}

# login <role> -- establish a session with curl and save the cookie jar.
#
# Classic form-post logins work here, which covers most server-rendered apps and
# many SPAs. When it fails (JS-only login, 2FA, CAPTCHA) fall back to
# /test-setup, which drives a real browser. Without a session the permission cases are
# meaningless -- they would all "pass" by virtue of being logged out.
cmd_login() {
  role="${1:?login: role required}"
  assert_target_allowed
  have curl || die "login: curl not found"
  base="$(json_get "$CREDS" base_url)"
  path="$(json_get "$CREDS" login.path 2>/dev/null)"; [ -n "$path" ] || path=/login
  ok="$(json_get "$CREDS" login.success_indicator 2>/dev/null)"; [ -n "$ok" ] || ok=/
  user="$(json_get "$CREDS" "roles.$role.username" 2>/dev/null)"
  pass="$(json_get "$CREDS" "roles.$role.password" 2>/dev/null)"
  [ -n "$user" ] && [ -n "$pass" ] || die "login: no username/password for role '$role' in $CREDS"

  mkdir -p "$TESTS_DIR/.auth"
  jar="$TESTS_DIR/.auth/$role.cookies"
  page="$CACHE/.login.$$"; mkdir -p "$CACHE"
  rm -f "$jar"

  curl -s -c "$jar" -o "$page" --max-time 20 "$base$path" || die "login: cannot fetch $base$path"

  # Field names vary; read them off the form rather than guessing.
  ufield="$(grep -oiE 'name="(email|username|user|login|identifier)"' "$page" | head -1 | sed -E 's/.*"(.*)"/\1/')"
  pfield="$(grep -oiE 'name="(password|pass|passwd)"' "$page" | head -1 | sed -E 's/.*"(.*)"/\1/')"
  [ -n "$ufield" ] || ufield=email
  [ -n "$pfield" ] || pfield=password

  # CSRF token, if the app uses one.
  csrf_name="$(grep -oiE 'name="(_csrf|csrf_token|csrfmiddlewaretoken|authenticity_token|__RequestVerificationToken)"' "$page" | head -1 | sed -E 's/.*"(.*)"/\1/')"
  csrf_arg=""
  if [ -n "$csrf_name" ]; then
    csrf_val="$(grep -oiE "name=\"$csrf_name\"[^>]*value=\"[^\"]*\"|value=\"[^\"]*\"[^>]*name=\"$csrf_name\"" "$page" |
                head -1 | grep -oE 'value="[^"]*"' | sed -E 's/value="(.*)"/\1/')"
    [ -n "$csrf_val" ] && csrf_arg="--data-urlencode $csrf_name=$csrf_val"
  fi
  rm -f "$page"

  # shellcheck disable=SC2086
  curl -s -b "$jar" -c "$jar" -o /dev/null --max-time 20 -L \
    --data-urlencode "$ufield=$user" --data-urlencode "$pfield=$pass" $csrf_arg \
    "$base$path" 2>/dev/null

  code="$(curl -s -b "$jar" -o /dev/null -w '%{http_code}' --max-time 20 \
           --max-redirs 0 "$base$ok" 2>/dev/null)"; [ -n "$code" ] || code=000
  case "$code" in
    2*) echo "login: $role authenticated (session -> $jar)" ;;
    *)  rm -f "$jar"
        die "login: $role failed -- $base$ok returned $code.
    The app likely uses a JavaScript login, SSO, or 2FA. Run /test-setup to
    log in through a real browser instead." ;;
  esac
}

# storage-state <role> -- convert a curl cookie jar into Playwright storage state.
#
# `login` writes tests/.auth/<role>.cookies, which only curl reads. Every
# browser case reads tests/.auth/<role>.json instead, and a role that has the
# jar but not the state looks logged in to the API pass and logged out to the
# browser pass -- so every permission case "passes" by virtue of being refused
# everything. This converts one to the other, HttpOnly cookies included, which
# is why it is preferred over reading cookies back out of a browser.
cmd_storage_state() {
  role="${1:?storage-state: role required}"
  jar="$TESTS_DIR/.auth/$role.cookies"
  out="$TESTS_DIR/.auth/$role.json"
  [ -f "$jar" ] || die "storage-state: no cookie jar for $role -- run: tf.sh login $role"
  mkdir -p "$TESTS_DIR/.auth"
  awk -v out="$out" -v q='"' '
    /^#HttpOnly_/ { ho = "true"; sub(/^#HttpOnly_/, "") }
    /^#/ { next }
    NF < 7 { next }
    function kv(k, v) { return q k q ": " q v q }
    {
      sec = (tolower($4) == "true") ? "true" : "false"
      ex = ($5 == "0") ? "-1" : $5
      if (ho != "true") ho = "false"
      n++
      c[n] = "    {" kv("name", $6) ", " kv("value", $7) ", " kv("domain", $1) ", " kv("path", $3) ", " q "expires" q ": " ex ", " q "httpOnly" q ": " ho ", " q "secure" q ": " sec ", " kv("sameSite", "Lax") "}"
      ho = ""
    }
    END {
      print "{" > out
      print "  " q "cookies" q ": [" > out
      for (i = 1; i <= n; i++) print c[i] (i < n ? "," : "") > out
      print "  ]," > out
      print "  " q "origins" q ": []" > out
      print "}" > out
      printf "storage-state: %d cookies -> %s\n", n, out
    }
  ' "$jar" >&2
  [ -s "$out" ] || die "storage-state: wrote nothing for $role -- jar was empty"
}
