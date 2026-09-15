# shellcheck shell=sh
# lib/auth.sh -- sessions: login, storage-state, preflight
#
# Sourced by scripts/tf.sh; defines functions only. See tf.sh for the paths
# and schema variables these rely on.

# =================================================================== execution

# preflight -- is the app up and does a login work? Fails fast so a down app
# costs one request instead of a whole suite of failures.
cmd_preflight() {
  assert_target_allowed
  base="$(json_get "$CREDS" base_url)"
  have curl || die3 "preflight: curl not found"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$base" 2>/dev/null)"; [ -n "$code" ] || code=000
  case "$code" in
    000) die3 "preflight: $base is unreachable. Start the app first." ;;
    5*)  die3 "preflight: $base returned $code. The app is up but erroring." ;;
  esac
  echo "preflight: $base -> $code"
  # Two session artifacts, and a run needs both: the jar is what curl reads, the
  # storage state is what every browser case reads. A role with only the jar
  # runs the browser pass logged out, and a logged-out user is refused
  # everything -- so every permission case "passes". Report the gap here.
  for role in $(json_keys "$CREDS" roles 2>/dev/null); do
    jar="$TESTS_DIR/.auth/$role.cookies"
    state="$TESTS_DIR/.auth/$role.json"
    if [ -f "$jar" ] && [ -f "$state" ]; then
      echo "preflight: session present for $role"
    elif [ -f "$jar" ]; then
      echo "preflight: $role has a cookie jar but no browser session (run: tf.sh storage-state $role)" >&2
    else
      echo "preflight: no session for $role (run /test-setup)" >&2
    fi
  done
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
