# shellcheck shell=sh
# lib/core.sh -- shared helpers: errors, the CSV awk library, JSON readers, guardrails
#
# Sourced by scripts/tf.sh; defines functions only. See tf.sh for the paths
# and schema variables these rely on.

# `--cols Test Case Steps` would need shell quoting on every call, so accept a
# one-word alias for each visible column. The names from before 1.0 are kept as
# aliases too: an older agent prompt asking for `todo` or `area` still works,
# and `who` resolves to the hidden `role` column where that meaning now lives.
alias_col() {
  case "$1" in
    id)                       echo 'Test Case ID' ;;
    module|area|feature)      echo 'Module' ;;
    scenario)                 echo 'Test Scenario' ;;
    description|desc|notes)   echo 'Test Description' ;;
    preconditions|precondition|pre) echo 'Preconditions' ;;
    steps|todo|do)            echo 'Test Case Steps' ;;
    data|testdata)            echo 'Test Data' ;;
    expected|expect|should)   echo 'Expected Result' ;;
    actual|result)            echo 'Actual Result' ;;
    status)                   echo 'Status' ;;
    who)                      echo 'role' ;;
    *)                        echo "$1" ;;
  esac
}

# The QA status words, and every older spelling that must land on one of them.
# Used wherever the engine compares or writes a status.
qa_status() {
  case "$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z')" in
    ''|new|'not run')          echo 'Not Run' ;;
    pass|passing|passed)       echo 'Pass' ;;
    fail|failing|failed)       echo 'Fail' ;;
    blocked|error|unjudged)    echo 'Blocked' ;;
    flaky)                     echo 'Flaky' ;;
    skip|skipped)              echo 'Skipped' ;;
    *)                         echo "$1" ;;
  esac
}

die() { echo "tf: $*" >&2; exit 1; }
# die3 -- "could not run", exit 3. Distinct from 1 (tests failed) and 2 (a
# security failure) so CI can tell a broken environment from a broken app. Used
# by the production guard and by preflight: neither is a test result.
die3() { echo "tf: $*" >&2; exit 3; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- awk library
# Shared RFC4180 parse/quote functions, prepended to every awk program.
# Records are one line each: newlines inside fields are forbidden by the schema
# (multi-step values are pipe-separated), which keeps this a line-oriented tool.
AWKLIB='
function csvsplit(line, arr,   n, i, c, f, inq) {
  n = 0; f = ""; inq = 0
  for (i = 1; i <= length(line); i++) {
    c = substr(line, i, 1)
    if (inq) {
      if (c == "\"") {
        if (substr(line, i+1, 1) == "\"") { f = f "\""; i++ } else inq = 0
      } else f = f c
    } else {
      if (c == "\"") inq = 1
      else if (c == ",") { arr[++n] = f; f = "" }
      else f = f c
    }
  }
  arr[++n] = f
  return n
}
function csvq(s) {
  if (s ~ /[",]/) { gsub(/"/, "\"\"", s); return "\"" s "\"" }
  return s
}
function csvjoin(arr, n,   i, out) {
  out = ""
  for (i = 1; i <= n; i++) out = out (i > 1 ? "," : "") csvq(arr[i])
  return out
}
function idcol(H) {
  # The visible store calls it "Test Case ID"; state.csv and every older
  # format call it "id". One helper so no caller has to know which it is.
  return ("id" in H) ? H["id"] : H["Test Case ID"]
}
function hdrmap(line, idx,   a, n, i) {
  n = csvsplit(line, a)
  for (i = 1; i <= n; i++) idx[a[i]] = i
  return n
}
'

awkcsv() { awk "$AWKLIB $1" "$@"; }

# --------------------------------------------------------------- json helpers
# Minimal readers for our own small, flat config files. Not a general JSON
# parser -- it only has to read files this framework wrote or templated.
json_get() { # json_get <file> <dotted.path>
  [ -f "$1" ] || return 1
  awk -v path="$2" '
    BEGIN { n = split(path, p, "."); depth = 0 }
    { line = line $0 }
    END {
      # walk nested objects by key, tolerating whitespace and nesting
      rest = line
      for (i = 1; i <= n; i++) {
        key = "\"" p[i] "\""
        pos = index(rest, key)
        if (pos == 0) exit 1
        rest = substr(rest, pos + length(key))
        sub(/^[ \t]*:[ \t]*/, "", rest)
      }
      if (substr(rest, 1, 1) == "\"") {
        rest = substr(rest, 2)
        print substr(rest, 1, index(rest, "\"") - 1)
      } else {
        match(rest, /^[^,}\]]+/)
        v = substr(rest, 1, RLENGTH); gsub(/[ \t]+$/, "", v); print v
      }
    }' "$1"
}

json_keys() { # json_keys <file> <object-key>  -> one key per line
  [ -f "$1" ] || return 1
  awk -v obj="$2" '
    { line = line $0 }
    END {
      pos = index(line, "\"" obj "\"")
      if (pos == 0) exit 1
      rest = substr(line, pos + length(obj) + 2)
      sub(/^[ \t]*:[ \t]*\{/, "", rest)
      depth = 1; buf = ""
      for (i = 1; i <= length(rest) && depth > 0; i++) {
        c = substr(rest, i, 1)
        if (c == "{") depth++
        else if (c == "}") { depth--; if (depth == 0) break }
        buf = buf c
      }
      # top-level keys of the captured object
      d = 0
      for (i = 1; i <= length(buf); i++) {
        c = substr(buf, i, 1)
        if (c == "{" || c == "[") d++
        else if (c == "}" || c == "]") d--
        else if (c == "\"" && d == 0) {
          j = i + 1; k = ""
          while (j <= length(buf) && substr(buf, j, 1) != "\"") { k = k substr(buf, j, 1); j++ }
          # only names immediately followed by a colon are keys
          rem = substr(buf, j + 1)
          if (rem ~ /^[ \t]*:/) print k
          i = j
          # skip this value entirely so nested keys are not emitted
          sub(/^[ \t]*:[ \t]*/, "", rem)
          if (substr(rem, 1, 1) == "{") {
            dd = 0
            for (m = 1; m <= length(rem); m++) {
              cc = substr(rem, m, 1)
              if (cc == "{") dd++
              else if (cc == "}") { dd--; if (dd == 0) break }
            }
            i = j + 1 + (length(buf) - length(rem)) - (length(buf) - length(rem)) + m
            i = length(buf) - length(rem) + m
          }
        }
      }
    }' "$1"
}

# ----------------------------------------------------------------- guardrails
# The production guard. Everything that touches the network goes through this,
# including run-api, which is otherwise the fastest way to hammer a live API.
assert_target_allowed() {
  base="$(json_get "$CREDS" base_url 2>/dev/null || true)"
  [ -n "$base" ] || die3 "no base_url in $CREDS"
  host="$(printf '%s' "$base" | sed -e 's#^[a-zA-Z]*://##' -e 's#[:/].*$##')"
  case "$host" in
    localhost|127.0.0.1|0.0.0.0|::1|*.local|*.localhost|host.docker.internal) return 0 ;;
  esac
  allow="$(json_get "$FRAMEWORK" allow_remote 2>/dev/null || echo false)"
  [ "$allow" = "true" ] && return 0
  die3 "refusing to run against remote host '$host'.
    base_url is not local and framework.json does not set \"allow_remote\": true.
    If '$host' really is a disposable test environment, set that flag explicitly."
}
