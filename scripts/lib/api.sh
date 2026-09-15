# shellcheck shell=sh
# lib/api.sh -- run-api: type=api cases over curl
#
# Sourced by scripts/tf.sh; defines functions only. See tf.sh for the paths
# and schema variables these rely on.

# run-api [--allow-destructive] -- execute `type=api` cases with curl.
#
# Only headless endpoints belong here. Anything that renders a page is a
# browser case now, because a permission check has to be judged by what the
# user actually sees: an "Access denied" body served with HTTP 200 passes a
# status-code check and is exactly the bug worth catching.
#
# Each case is a real request, described by state columns:
#
#   method   GET (default), POST, PUT, PATCH, DELETE, ...
#   body     inline text, or @path relative to tests/ (e.g. @api/bodies/X.json)
#   headers  `Name: value` pairs separated by |
#   expect_code  what settles the verdict: 200, 2xx, 4xx, 401|403, refused
#   repeat   send N times and judge the last response (lockouts, rate limits)
#
# Body and headers may use {{cookie:NAME}} (from the role's session),
# {{secret:NAME}} (credentials.json "secrets"), {{env:NAME}}, and in headers
# {{hmac-sha256:NAME}} -- the hex HMAC of the body under that secret.
#
# A case the runner cannot judge is UNJUDGED, never FAIL: a POST with no
# `expect_code`, a 405 on a case that never said which method to use, a missing
# secret. Reporting those as failures buried the real ones.
cmd_run_api() {
  need_csv
  assert_target_allowed
  have curl || die "run-api: curl not found"
  base="$(json_get "$CREDS" base_url)"
  mkdir -p "$RESULTS" "$CACHE"
  ts="$(date +%Y%m%d-%H%M%S)"
  out="$RESULTS/run-$ts.csv"
  echo 'id,type,role,route,expected,actual,verdict,ms' > "$out"

  allow_destructive=0
  [ "${1:-}" = "--allow-destructive" ] && allow_destructive=1

  # Unit-separated, not tab-separated: `read` collapses runs of whitespace
  # delimiters, so an empty column between two tabs would shift every column
  # after it. \037 is not whitespace, and cannot appear in a case.
  US="$(printf '\037')"
  work="$CACHE/.http.$$"
  cmd_select --type api --cols id,type,who,route,tags,status,method,body,headers,expect_code,repeat \
    --format csv 2>/dev/null |
    awk -v us="$US" "$AWKLIB"'NR > 1 { n = csvsplit($0, F); o = F[1]
      for (i = 2; i <= 11; i++) o = o us F[i]; print o }' > "$work"

  roles="$(json_keys "$CREDS" roles 2>/dev/null | tr '\n' ' ')"

  # Which roles have no session? Cases for those roles are logged-out requests,
  # so a "denied" verdict proves nothing -- they are unverified, not passed.
  # Reporting them as green is the worst failure mode this tool has.
  nosession=""; unverified=0
  for who in $(awk -F"$US" '{ print $3 }' "$work" | sort -u | tr ' ' '+'); do
    who="$(printf '%s' "$who" | tr '+' ' ')"
    r="$(_api_role "$who")"
    [ -n "$r" ] || continue
    [ -f "$TESTS_DIR/.auth/$r.cookies" ] && continue
    nosession="$nosession${nosession:+ }$r"
    unverified=$((unverified + $(awk -F"$US" -v w="$who" '$3 == w { n++ } END { print n + 0 }' "$work")))
  done

  run_t0=$(date +%s%N 2>/dev/null || echo 0)
  _tf_progress_init "$(grep -c . "$work" 2>/dev/null || echo 0)"
  skip=0; unjudged=0
  while IFS="$US" read -r id typ who route tags status method body headers expect_code repeat; do
    [ -n "${id:-}" ] || continue
    [ "$(qa_status "$status")" = "Skipped" ] && { skip=$((skip + 1)); _tf_progress_tick SKIP "$typ" "$id"; continue; }
    case "$tags" in
      *destructive*) [ "$allow_destructive" = "1" ] || \
        { skip=$((skip + 1)); _tf_progress_tick SKIP "$typ" "$id"; continue; } ;;
    esac
    [ -n "$route" ] || { _tf_progress_tick SKIP "$typ" "$id"; continue; }

    m="$(printf '%s' "${method:-GET}" | tr 'a-z' 'A-Z')"
    shown="$route"; [ "$m" = GET ] || shown="$m $route"

    t0=$(date +%s%N 2>/dev/null || echo 0)
    reason=""; actual=""
    _api_prepare "$id" "$(_api_role "$who")" "$m" "$body" "$headers" "$route" "$tags" || reason="$API_WHY"
    if [ -z "$reason" ]; then
      set -- -s -o /dev/null -w '%{http_code}' --max-time 20 --max-redirs 0
      [ "$m" = GET ] || set -- "$@" -X "$m"
      [ -f "$API_TMP.jar" ] && set -- "$@" -b "$API_TMP.jar" -c "$API_TMP.jar"
      [ -f "$API_TMP.body" ] && set -- "$@" --data-binary "@$API_TMP.body"
      while IFS= read -r h; do set -- "$@" -H "$h"; done < "$API_TMP.hdr"
      n="${repeat:-1}"; case "$n" in ''|*[!0-9]*|0) n=1 ;; esac
      i=0; codes=""
      while [ "$i" -lt "$n" ]; do
        code="$(curl "$@" "$base$route" 2>/dev/null)"; [ -n "$code" ] || code=000
        codes="$codes $code"; i=$((i + 1))
      done
      actual="$(_api_compact $codes)"
    fi
    t1=$(date +%s%N 2>/dev/null || echo 0)
    ms=$(( (t1 - t0) / 1000000 )); [ "$ms" -lt 0 ] && ms=0

    if [ -n "$reason" ]; then
      verdict=UNJUDGED; expected="$reason"; actual="-"
    else
      _api_verdict "$code" "$expect_code" "$tags" "$method"; verdict="$VERDICT"
      expected="${expect_code:-denied-or-2xx}"
      [ "$verdict" = UNJUDGED ] && expected="$API_WHY"
    fi
    [ "$verdict" = UNJUDGED ] && unjudged=$((unjudged + 1))
    _api_cleanup

    # Result rows are read with a plain comma split everywhere, so no field may
    # contain one.
    printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "$id" "$typ" "$who" \
      "$(_api_nocomma "$shown")" "$(_api_nocomma "$expected")" "$actual" "$verdict" "$ms" >> "$out"

    _tf_progress_tick "$verdict" "$typ" "$id"
  done < "$work"
  _tf_progress_done
  rm -f "$work"

  # Fold verdicts back into the store in a single pass. An ERROR (the request
  # never completed) or an UNJUDGED case says nothing about the app, so neither
  # may read as Pass or Fail -- they become `Blocked`, the QA word for "this
  # could not be judged", which keeps them visibly out of both columns.
  now="$(date +%Y-%m-%dT%H:%M:%S)"
  # `Actual Result` is a visible column now, so a run records what it saw
  # rather than leaving the tester to guess. setmany reads `+` as a space.
  awk -F, -v now="$now" 'NR > 1 {
    st = ($7 == "PASS") ? " status=Pass" : \
         (($7 == "FAIL") ? " status=Fail" : \
         ((($7 == "ERROR") || ($7 == "UNJUDGED")) ? " status=Blocked" : ""))
    act = $6
    # A bare status code means little to a tester reading the sheet.
    if (act ~ /^[0-9]/) act = "HTTP " act
    if (act != "" && act != "-") { gsub(/ /, "+", act); act = " actual=" act }
    else act = ""
    print $1 st act " last_result=" $7 " last_run=" now
  }' "$out" | cmd_setmany

  run_t1=$(date +%s%N 2>/dev/null || echo 0)
  {
    echo "time=$(date +%H:%M:%S)"
    echo "duration_ms=$(( (run_t1 - run_t0) / 1000000 ))"
    echo "skipped=$skip"
    echo "nosession=$(printf '%s' "$nosession" | tr ' ' ',')"
    echo "unverified=$unverified"
    echo "unjudged=$unjudged"
  } > "${out%.csv}.meta"

  cmd_summary "$out"
}

# _api_role <who> -- the credentials.json role key behind a `who` value.
# Generated cases say "normal user", the key is usually `user`: without this
# mapping such a case never finds its session and silently runs logged out.
_api_role() {
  case "$1" in
    ""|nobody|anonymous) return 0 ;;
    "normal user")
      for k in user member staff employee; do
        case " $roles " in *" $k "*) echo "$k"; return 0 ;; esac
      done
      echo user ;;
    *) echo "$1" ;;
  esac
}

# _api_prepare <id> <role> <method> <body> <headers> <route> <tags> -- stage the
# request as files under $API_TMP: .jar (the session to send), .body, .hdr (one
# header per line). The caller turns those into curl arguments. Returns 1 with
# API_WHY set when the request cannot be built.
_api_prepare() {
  API_WHY=""; API_TMP="$CACHE/.api.$$"
  _p_id="$1"; _p_role="$2"; _p_m="$3"; _p_body="$4"; _p_hdrs="$5"; _p_route="$6"; _p_tags="$7"
  rm -rf "$API_TMP".*
  : > "$API_TMP.hdr"

  # The request gets a copy of the session, so a rotated cookie changes nothing
  # for the cases after it. A copy cannot survive a server-side sign-out or a
  # lockout, though: those end the session id itself. So a case that ends its
  # session -- a sign-out route, or tagged ends-session -- logs in afresh and
  # spends that throwaway session instead of the run's.
  _p_jar=""
  if [ -n "$_p_role" ]; then
    _p_ends=0
    case "$_p_tags" in *ends-session*) _p_ends=1 ;; esac
    printf '%s' "$_p_route" | grep -qiE '(log|sign)[-_]?(out|off)' && _p_ends=1
    if [ "$_p_ends" = 1 ]; then
      mkdir -p "$API_TMP.login/.auth"
      if ( TESTS_DIR="$API_TMP.login"; CACHE="$API_TMP.login"; cmd_login "$_p_role" ) >/dev/null 2>&1; then
        cp "$API_TMP.login/.auth/$_p_role.cookies" "$API_TMP.jar"; _p_jar="$API_TMP.jar"
      else
        API_WHY="ends its session and $_p_role cannot log in with curl for a throwaway one"
        return 1
      fi
    elif [ -f "$TESTS_DIR/.auth/$_p_role.cookies" ]; then
      cp "$TESTS_DIR/.auth/$_p_role.cookies" "$API_TMP.jar"; _p_jar="$API_TMP.jar"
    fi
  fi

  if [ -n "$_p_body" ]; then
    case "$_p_body" in
      @*) [ -f "$TESTS_DIR/${_p_body#@}" ] || { API_WHY="no body file tests/${_p_body#@}"; return 1; }
          cp "$TESTS_DIR/${_p_body#@}" "$API_TMP.body" ;;
      *)  printf '%s' "$_p_body" > "$API_TMP.body" ;;
    esac
  fi
  if [ -n "$_p_hdrs" ]; then
    printf '%s\n' "$_p_hdrs" | tr '|' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep . > "$API_TMP.hdr"
  fi

  case "$_p_body$_p_hdrs" in *'{{'*) _api_placeholders "$_p_jar" || return 1 ;; esac

  if [ -f "$API_TMP.body" ] && ! grep -qi '^content-type:' "$API_TMP.hdr"; then
    case "$(tr -d ' \t\r\n' < "$API_TMP.body" | cut -c1)" in
      '{'|'[') echo 'Content-Type: application/json' >> "$API_TMP.hdr" ;;
      *)       echo 'Content-Type: application/x-www-form-urlencoded' >> "$API_TMP.hdr" ;;
    esac
  fi
  return 0
}

# _api_placeholders <jar> -- resolve {{kind:NAME}} in the body and headers.
_api_placeholders() {
  _h_jar="$1"
  for _h_tok in $(cat "$API_TMP.body" "$API_TMP.hdr" 2>/dev/null |
                  grep -oE '\{\{(cookie|secret|env):[A-Za-z0-9_.-]+\}\}' | sort -u); do
    _h_kind="${_h_tok#\{\{}"; _h_kind="${_h_kind%%:*}"
    _h_name="${_h_tok#*:}"; _h_name="${_h_name%\}\}}"
    case "$_h_kind" in
      cookie) _h_val="$( [ -n "$_h_jar" ] && awk -v n="$_h_name" '{ sub(/^#HttpOnly_/, "") } !/^#/ && NF >= 7 && $6 == n { v = $7 } END { print v }' "$_h_jar")" ;;
      secret) _h_val="$(json_get "$CREDS" "secrets.$_h_name" 2>/dev/null)" ;;
      env)    _h_val="$(printenv "$_h_name" 2>/dev/null)" ;;
    esac
    [ -n "$_h_val" ] || { API_WHY="no value for $_h_tok"; return 1; }
    _api_subst "$_h_tok" "$_h_val" "$API_TMP.body" "$API_TMP.hdr"
  done

  # Signatures last, over the finished body.
  for _h_tok in $(grep -oE '\{\{hmac-sha256:[A-Za-z0-9_.-]+\}\}' "$API_TMP.hdr" 2>/dev/null | sort -u); do
    have openssl || { API_WHY="signing needs openssl"; return 1; }
    _h_name="${_h_tok#*:}"; _h_name="${_h_name%\}\}}"
    _h_key="$(json_get "$CREDS" "secrets.$_h_name" 2>/dev/null)"
    [ -n "$_h_key" ] || { API_WHY="no secret $_h_name in credentials.json"; return 1; }
    [ -f "$API_TMP.body" ] || : > "$API_TMP.body"
    _h_sig="$(openssl dgst -sha256 -hmac "$_h_key" < "$API_TMP.body" 2>/dev/null | awk '{ print $NF }')"
    [ -n "$_h_sig" ] || { API_WHY="openssl could not sign"; return 1; }
    _api_subst "$_h_tok" "$_h_sig" "$API_TMP.hdr"
  done
  return 0
}

# _api_subst <token> <value> <file>... -- literal replace. Values travel through
# ENVIRON because `awk -v` would interpret backslashes in them. A file keeps
# exactly its trailing newline, or lack of one: signatures are computed over
# the body's exact bytes.
_api_subst() {
  _s_t="$1"; _s_v="$2"; shift 2
  for _s_f in "$@"; do
    [ -s "$_s_f" ] || continue
    _s_nl=1; [ -n "$(tail -c 1 "$_s_f")" ] && _s_nl=0
    T="$_s_t" V="$_s_v" awk -v nl="$_s_nl" 'BEGIN { t = ENVIRON["T"]; v = ENVIRON["V"] }
      { out = ""; while ((i = index($0, t)) > 0) { out = out substr($0, 1, i - 1) v; $0 = substr($0, i + length(t)) }
        printf "%s%s", (NR > 1 ? "\n" : ""), out $0 }
      END { if (nl) printf "\n" }' "$_s_f" > "$_s_f.new"
    mv "$_s_f.new" "$_s_f"
  done
}

_api_cleanup() { rm -rf "$CACHE/.api.$$".*; }

# _api_compact <code>... -- "401 401 401 429" -> "401x3;429"
_api_compact() {
  printf '%s\n' "$@" | awk '
    { if ($0 == prev) n++; else { flush(); prev = $0; n = 1 } }
    function flush() { if (n) out = out (out == "" ? "" : ";") prev (n > 1 ? "x" n : "") }
    END { flush(); print out }'
}

_api_nocomma() { printf '%s' "$1" | tr ',' ';'; }

# _api_match <code> <expect> -- does the code satisfy the expectation?
_api_match() {
  _m_code="$1"
  _m_old="$IFS"; IFS='|'
  # shellcheck disable=SC2086
  set -- $2
  IFS="$_m_old"
  for _m_alt in "$@"; do
    _m_alt="$(printf '%s' "$_m_alt" | tr -d ' ' | tr 'X' 'x')"
    case "$_m_alt" in
      refused) case "$_m_code" in 401|403|404|302|303|307) return 0 ;; esac ;;
      [1-5]xx) [ "${_m_code%??}" = "${_m_alt%xx}" ] && return 0 ;;
      *)       [ "$_m_code" = "$_m_alt" ] && return 0 ;;
    esac
  done
  return 1
}

# _api_verdict <last code> <expect> <tags> <method column> -- sets VERDICT to
# PASS, FAIL, ERROR or UNJUDGED, and API_WHY for UNJUDGED. Not called in a
# subshell, so both survive.
_api_verdict() {
  _v_code="$1"; _v_expect="$2"; _v_tags="$3"; _v_method="$4"
  API_WHY=""
  [ "$_v_code" = 000 ] && { VERDICT=ERROR; return; }

  if [ -n "$_v_expect" ]; then
    if _api_match "$_v_code" "$_v_expect"; then VERDICT=PASS; else VERDICT=FAIL; fi
    return
  fi

  # No expectation. A plain GET keeps the old rule; anything else cannot be
  # judged, because nobody said what success looks like.
  _v_m="$(printf '%s' "$_v_method" | tr 'a-z' 'A-Z')"
  if [ -n "$_v_m" ] && [ "$_v_m" != GET ]; then
    API_WHY="no expect_code set for $_v_m"; VERDICT=UNJUDGED; return
  fi
  if [ "$_v_code" = 405 ] && [ -z "$_v_method" ]; then
    API_WHY="endpoint rejects GET - set method"; VERDICT=UNJUDGED; return
  fi

  # `refused` cases assert a denial, so the pass/fail sense is inverted:
  # a 200 on an endpoint that should reject you is the bug being hunted.
  case "$_v_tags" in
    *refused*) case "$_v_code" in 2*) VERDICT=FAIL ;; *) VERDICT=PASS ;; esac ;;
    *)         case "$_v_code" in 2*) VERDICT=PASS ;; *) VERDICT=FAIL ;; esac ;;
  esac
}
