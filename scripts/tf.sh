#!/bin/sh
# tf.sh - deterministic engine for the Claude test framework.
#
# Runs in Claude's own Bash tool. POSIX sh + awk + curl only; never a
# dependency of the project under test.
#
# Everything here exists so the model does not have to do it. If you are an
# agent reading this: never `cat` testcases.csv, always query it.
#
# Usage: tf.sh <subcommand> [options]   |   tf.sh help

set -u

TESTS_DIR="${TF_TESTS_DIR:-tests}"
CACHE="$TESTS_DIR/.cache"
XLSX="$TESTS_DIR/testcases.xlsx"

# Where the CSV lives. tests/testcases.xlsx is the store a person opens; the CSV
# is the copy awk can read, and new suites keep it out of sight in .cache/. A
# suite created before the workbook existed keeps its top-level CSV and goes on
# working untouched -- `tf.sh migrate` is what moves it.
if [ -f "$TESTS_DIR/testcases.csv" ]; then
  CSV="$TESTS_DIR/testcases.csv"
else
  CSV="$CACHE/testcases.csv"
fi
RESULTS="$TESTS_DIR/results"
CREDS="$TESTS_DIR/credentials.json"
FRAMEWORK="$TESTS_DIR/framework.json"

STATE="$CACHE/state.csv"

# Two files, on purpose.
#
# testcases.csv is for a person: eight columns, plain words, opens in Excel.
# A run rewrites exactly one of its cells -- `status` -- and only when a verdict
# actually changed, so the file does not churn in git and hand edits survive.
#
# .cache/state.csv is the bookkeeping the runner needs and nobody wants to read.
# Keyed by id, regenerable, never hand-edited.
HEADER='id,area,who,what to do,what should happen,priority,status,notes'
STATE_HEADER='id,type,route,tags,source_files,spec_file,last_run,last_result,pass_streak,flake_count,viewport'

# Columns that live in testcases.csv. Everything else is routed to state.csv.
HUMAN_COLS='id area who what to do what should happen priority status notes'

# `--cols what to do` would need shell quoting, so accept short aliases.
alias_col() {
  case "$1" in
    todo|do|steps)        echo 'what to do' ;;
    expect|should|expected) echo 'what should happen' ;;
    role)                 echo 'who' ;;
    feature)              echo 'area' ;;
    *)                    echo "$1" ;;
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
function hdrmap(line, idx,   a, n, i) {
  n = csvsplit(line, a)
  for (i = 1; i <= n; i++) idx[a[i]] = i
  return n
}
'

awkcsv() { awk "$AWKLIB $1" "$@"; }

need_csv() { [ -f "$CSV" ] || die "no $CSV (run /test-setup first)"; }

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

# ====================================================================== progress
#
# Claude's Bash tool does not stream output and does not interpret carriage
# returns -- `printf 'a\rb'` arrives as "ab". A \r progress bar is therefore
# useless there and fine in a real terminal, so this picks a renderer per
# context instead of pretending one works everywhere.
#
#   tty         one \r line, erased before the summary panel
#   checkpoint  throttled plain lines, capped, safe in logs and scrollback
#   off         nothing
#
# All progress goes to stderr so stdout stays clean for --json and pipes.

_P_MODE=off; _P_TOTAL=0; _P_DONE=0; _P_PASS=0; _P_FAIL=0; _P_ERR=0
_P_START=0; _P_LAST_T=0; _P_LAST_PCT=0; _P_LINES=0; _P_SECSHOWN=0
_P_MAXLINES=10; _P_SECMAX=5; _P_DIRTY=0

_tf_ms() { d=$(date +%s%N 2>/dev/null) || d=0; echo $(( d / 1000000 )); }

_tf_progress_mode() {
  case "${TF_PROGRESS:-}" in 0|off|none) echo off; return ;; esac
  case "${1:-}" in tty|checkpoint|off) echo "$1"; return ;; esac
  if [ -t 2 ]; then echo tty; else echo checkpoint; fi
}

# _tf_bar <done> <total> <width> <full> <empty>
_tf_bar() {
  _bw="$3"; _bf=0
  [ "$2" -gt 0 ] && _bf=$(( $1 * _bw / $2 ))
  [ "$_bf" -gt "$_bw" ] && _bf="$_bw"
  _out=""; _i=0
  while [ "$_i" -lt "$_bf" ]; do _out="$_out$4"; _i=$((_i + 1)); done
  while [ "$_i" -lt "$_bw" ]; do _out="$_out$5"; _i=$((_i + 1)); done
  printf '%s' "$_out"
}

_tf_progress_init() {
  _P_TOTAL="$1"; _P_DONE=0; _P_PASS=0; _P_FAIL=0; _P_ERR=0
  _P_LINES=0; _P_SECSHOWN=0; _P_LAST_PCT=0
  _P_START="$(_tf_ms)"; _P_LAST_T="$_P_START"
  _P_MODE="$(_tf_progress_mode "${TF_PROGRESS_MODE:-}")"
  mkdir -p "$CACHE"
  _tf_progress_write running "" ""
}

# The status file is the primitive that makes progress observable from outside
# the run -- `tf.sh watch`, a background run, or a Phase 2 browser agent that
# cannot print anywhere the main thread can see.
_tf_progress_write() {
  [ -n "${CACHE:-}" ] || return 0
  _pt="$CACHE/.progress.$$"
  printf 'state=%s total=%s done=%s pass=%s fail=%s error=%s type=%s id=%s started=%s updated=%s\n' \
    "$1" "$_P_TOTAL" "$_P_DONE" "$_P_PASS" "$_P_FAIL" "$_P_ERR" \
    "${2:-}" "${3:-}" "$_P_START" "$(_tf_ms)" > "$_pt" 2>/dev/null &&
    mv -f "$_pt" "$CACHE/progress" 2>/dev/null || rm -f "$_pt" 2>/dev/null
}

_tf_eta() {   # only once the average means something
  [ "$_P_DONE" -ge 5 ] || return 1
  _el=$(( $(_tf_ms) - _P_START ))
  [ "$_el" -gt 0 ] || return 1
  _rem=$(( (_el * (_P_TOTAL - _P_DONE)) / _P_DONE ))
  printf 'eta %d.%01ds' $(( _rem / 1000 )) $(( (_rem % 1000) / 100 ))
}

# _tf_progress_tick <verdict> <type> <id>
_tf_progress_tick() {
  _P_DONE=$((_P_DONE + 1))
  case "$1" in
    PASS)  _P_PASS=$((_P_PASS + 1)) ;;
    ERROR) _P_ERR=$((_P_ERR + 1)) ;;
    SKIP)  : ;;
    *)     _P_FAIL=$((_P_FAIL + 1)) ;;
  esac
  _tf_progress_write running "$2" "$3"
  [ "$_P_MODE" = off ] && return 0

  _now="$(_tf_ms)"; _since=$(( _now - _P_LAST_T ))
  _pct=0; [ "$_P_TOTAL" -gt 0 ] && _pct=$(( _P_DONE * 100 / _P_TOTAL ))
  _final=0; [ "$_P_DONE" -ge "$_P_TOTAL" ] && _final=1
  _el=$(( _now - _P_START ))

  if [ "$_P_MODE" = tty ]; then
    # redraw at most ~10x/sec; the final frame always draws
    [ "$_since" -lt 100 ] && [ "$_final" = 0 ] && return 0
    _P_LAST_T="$_now"
    _b="$(_tf_bar "$_P_DONE" "$_P_TOTAL" 20 "$(_tf_glyph_full)" "$(_tf_glyph_empty)")"
    _eta="$(_tf_eta || true)"
    printf '\r\033[K  %s  %d/%d  %d%%  %-5s %s' \
      "$_b" "$_P_DONE" "$_P_TOTAL" "$_pct" "$2" "$_eta" >&2
    return 0
  fi

  # checkpoint: needs BOTH a real step forward AND real time passed, and is
  # capped, because every one of these lines lands in the model's context.
  if [ "$_final" = 1 ]; then
    [ "$_P_LINES" -ge "$_P_MAXLINES" ] && return 0
  else
    [ $(( _pct - _P_LAST_PCT )) -ge 10 ] || return 0
    [ "$_since" -ge 2000 ] || return 0
    [ "$_P_LINES" -lt $(( _P_MAXLINES - 1 )) ] || return 0
  fi
  _P_LAST_T="$_now"; _P_LAST_PCT="$_pct"; _P_LINES=$((_P_LINES + 1))
  printf '%-6s [%s] %4d/%-4d %3d%%  %d.%01ds\n' \
    "$2" "$(_tf_bar "$_P_DONE" "$_P_TOTAL" 10 '#' '-')" \
    "$_P_DONE" "$_P_TOTAL" "$_pct" $(( _el / 1000 )) $(( (_el % 1000) / 100 )) >&2
}

_tf_glyph_full()  { [ "${TF_ASCII:-0}" = 1 ] && printf '#' || printf '\342\226\210'; }
_tf_glyph_empty() { [ "${TF_ASCII:-0}" = 1 ] && printf '-' || printf '\342\226\221'; }

# A privilege boundary crossing is worth interrupting for at second 2 rather
# than second 40. An ordinary failure is not -- it waits for the panel.
_tf_progress_security() {
  [ "$_P_MODE" = off ] && return 0
  [ "$_P_SECSHOWN" -lt "$_P_SECMAX" ] || return 0
  _P_SECSHOWN=$((_P_SECSHOWN + 1))
  [ "$_P_MODE" = tty ] && printf '\r\033[K' >&2
  printf '  !! %-15s %-9s -> %-24s %s\n' "$1" "${2:-nobody}" "$3" "$4" >&2
}

_tf_progress_done() {
  _tf_progress_write done "" ""
  [ "$_P_MODE" = tty ] && printf '\r\033[K' >&2
  return 0
}

# watch -- render a live bar from the status file, for a second terminal or a
# backgrounded run.
cmd_watch() {
  [ -f "$CACHE/progress" ] || die "watch: no run in progress (no $CACHE/progress)"
  while :; do
    # shellcheck disable=SC2046
    eval $(sed -e 's/[^a-z_=0-9 -]//g' -e 's/\([a-z_]*\)=/W_\1=/g' "$CACHE/progress" 2>/dev/null)
    W_state="${W_state:-unknown}"; W_done="${W_done:-0}"; W_total="${W_total:-0}"
    _b="$(_tf_bar "$W_done" "$W_total" 24 "$(_tf_glyph_full)" "$(_tf_glyph_empty)")"
    _p=0; [ "$W_total" -gt 0 ] && _p=$(( W_done * 100 / W_total ))
    printf '\r\033[K  %s  %d/%d  %d%%  pass %s fail %s' \
      "$_b" "$W_done" "$W_total" "$_p" "${W_pass:-0}" "${W_fail:-0}"
    [ "$W_state" = running ] || { printf '\n'; break; }
    command sleep 1 2>/dev/null || break
  done
}

# ====================================================================== CSV ops

cmd_init_csv() {
  # Create the whole layout, not just the CSV. Other subcommands write into
  # these directories and should not each have to guess whether they exist.
  mkdir -p "$TESTS_DIR" "$CACHE" "$RESULTS" "$TESTS_DIR/.auth" "$TESTS_DIR/evidence"
  [ -f "$STATE" ] || printf '%s\n' "$STATE_HEADER" > "$STATE"
  [ -f "$CSV" ] && { echo "exists: $CSV"; return 0; }
  printf '%s\n' "$HEADER" > "$CSV"
  echo "created: $CSV"
}

need_state() {
  [ -f "$STATE" ] && return 0
  mkdir -p "$CACHE"          # a suite may exist without .cache/ ever being made
  printf '%s\n' "$STATE_HEADER" > "$STATE"
}

# Join testcases.csv with .cache/state.csv on id, emitting one wide row per
# case. Everything that needs a bookkeeping column reads through this, so the
# two-file split stays invisible to the rest of the script.
joined() {
  need_state
  awk "$AWKLIB"'
    NR == FNR {
      if (FNR == 1) { ns = hdrmap($0, SH); shdr = $0; next }
      n = csvsplit($0, S)
      ST[S[SH["id"]]] = $0
      next
    }
    FNR == 1 {
      nh = hdrmap($0, H); hsplit = csvsplit($0, HA)
      # emit the combined header once
      line = $0
      m = csvsplit(shdr, SA)
      for (i = 2; i <= m; i++) line = line "," csvq(SA[i])
      print line
      next
    }
    {
      n = csvsplit($0, F); id = F[H["id"]]
      line = $0
      m = csvsplit(shdr, SA)
      if (id in ST) { k = csvsplit(ST[id], SF)
        for (i = 2; i <= m; i++) line = line "," csvq(SF[i]) }
      else for (i = 2; i <= m; i++) line = line ","
      print line
    }
  ' "$STATE" "$CSV"
}

# select --status new --priority P0 --feature auth --cols id,steps [--count]
cmd_select() {
  need_csv
  filters=''; cols=''; limit=0; count=0; format=csv
  while [ $# -gt 0 ]; do
    case "$1" in
      --cols)   cols=""; for _c in $(printf '%s' "$2" | tr ',' ' '); do
                  cols="$cols${cols:+,}$(alias_col "$_c")"; done; shift 2 ;;
      --limit)  limit="$2"; shift 2 ;;
      --count)  count=1; shift ;;
      --format) format="$2"; shift 2 ;;
      --tag)    filters="$filters|tags~$2"; shift 2 ;;
      --where)  filters="$filters|$2"; shift 2 ;;
      --*)      filters="$filters|$(alias_col "$(printf '%s' "$1" | sed 's/^--//')")=$2"; shift 2 ;;
      *) die "select: unexpected argument '$1'" ;;
    esac
  done
  joined | awk -v filters="$filters" -v cols="$cols" -v limit="$limit" \
      -v count="$count" -v format="$format" "$AWKLIB"'
    NR == 1 { hdrmap($0, H); hdr = $0; nh = csvsplit($0, HA); next }
    {
      n = csvsplit($0, F)
      nf = split(filters, FS_, "|")
      for (i = 1; i <= nf; i++) {
        if (FS_[i] == "") continue
        neg = 0
        if (index(FS_[i], "~") > 0 && index(FS_[i], "=") == 0) {
          k = substr(FS_[i], 1, index(FS_[i], "~") - 1)
          v = substr(FS_[i], index(FS_[i], "~") + 1)
          if (!(k in H)) next
          if (index("," F[H[k]] ",", "," v ",") == 0) next
          continue
        }
        k = substr(FS_[i], 1, index(FS_[i], "=") - 1)
        v = substr(FS_[i], index(FS_[i], "=") + 1)
        if (!(k in H)) next
        # comma-separated value list means OR
        if (index(v, ",") > 0) {
          ok = 0; m = split(v, VL, ",")
          for (j = 1; j <= m; j++) if (F[H[k]] == VL[j]) ok = 1
          if (!ok) next
        } else if (F[H[k]] != v) next
      }
      matched++
      if (count) next
      if (limit > 0 && matched > limit) next
      if (!printed_hdr && format == "csv") {
        if (cols == "") print hdr
        else { m = split(cols, C, ","); line = ""
               for (i = 1; i <= m; i++) line = line (i > 1 ? "," : "") C[i]
               print line }
        printed_hdr = 1
      }
      if (cols == "") { print $0; next }
      m = split(cols, C, ","); out = ""
      for (i = 1; i <= m; i++) {
        v = (C[i] in H) ? F[H[C[i]]] : ""
        out = out (i > 1 ? (format == "plain" ? "\t" : ",") : "") (format == "plain" ? v : csvq(v))
      }
      print out
    }
    END { if (count) print matched + 0 }
  '
}

# set <id> col=value [col=value ...]
#
# Routes each assignment to whichever file owns that column. `status` and
# `notes` live in testcases.csv; everything else is bookkeeping and goes to
# .cache/state.csv. The human file is rewritten only if a value actually
# changed, so a run that changes nothing leaves it untouched in git.
cmd_set() {
  need_csv; need_state
  id="$1"; shift
  [ $# -gt 0 ] || die "set: no assignments given"
  human=''; state=''
  for a in "$@"; do
    k="${a%%=*}"; k="$(alias_col "$k")"
    case " $HUMAN_COLS " in
      *" $k "*) human="$human|$k=${a#*=}" ;;
      *)        state="$state|$k=${a#*=}" ;;
    esac
  done
  [ -n "$human" ] && _tf_apply "$CSV" "$id" "$human" 0
  [ -n "$state" ] && _tf_apply "$STATE" "$id" "$state" 1
  return 0
}

# _tf_apply <file> <id> <|-separated assigns> <create-if-missing>
_tf_apply() {
  _f="$1"; _id="$2"; _as="$3"; _create="$4"
  _t="$_f.tmp.$$"
  awk -v id="$_id" -v assigns="$_as" -v create="$_create" "$AWKLIB"'
    NR == 1 { nh = hdrmap($0, H); nhdr = nh; print; next }
    {
      n = csvsplit($0, F)
      if (F[H["id"]] == id) {
        na = split(assigns, A, "|"); changed = 0
        for (i = 1; i <= na; i++) {
          if (A[i] == "") continue
          k = substr(A[i], 1, index(A[i], "=") - 1)
          v = substr(A[i], index(A[i], "=") + 1)
          if ((k in H) && F[H[k]] != v) { F[H[k]] = v; changed = 1 }
        }
        found = 1
        if (changed) { dirty = 1; print csvjoin(F, n) } else print
        next
      }
      print
    }
    END {
      if (!found && create) {
        for (i = 1; i <= nhdr; i++) R[i] = ""
        R[H["id"]] = id
        na = split(assigns, A, "|")
        for (i = 1; i <= na; i++) {
          if (A[i] == "") continue
          k = substr(A[i], 1, index(A[i], "=") - 1)
          v = substr(A[i], index(A[i], "=") + 1)
          if (k in H) R[H[k]] = v
        }
        print csvjoin(R, nhdr); dirty = 1
      } else if (!found)
        print "tf: set: no such id: " id > "/dev/stderr"
      exit (dirty ? 0 : 9)      # 9 = nothing changed, keep the original file
    }
  ' "$_f" > "$_t"
  _rc=$?
  if [ "$_rc" = 0 ]; then mv "$_t" "$_f"; else rm -f "$_t"; fi
  return 0
}

# bulk-set from stdin: lines of "id col=value col=value"
cmd_setmany() {
  need_csv; need_state
  upd="$CACHE/.setmany.$$"; mkdir -p "$CACHE"; cat > "$upd"
  for _f in "$CSV" "$STATE"; do
    _t="$_f.tmp.$$"
    awk -v upd="$upd" "$AWKLIB"'
      BEGIN { while ((getline l < upd) > 0) { split(l, p, " "); U[p[1]] = l } }
      NR == 1 { hdrmap($0, H); print; next }
      {
        n = csvsplit($0, F); id = F[H["id"]]
        if (id in U) {
          np = split(U[id], P, " "); changed = 0
          for (i = 2; i <= np; i++) {
            k = substr(P[i], 1, index(P[i], "=") - 1)
            v = substr(P[i], index(P[i], "=") + 1)
            gsub(/\+/, " ", v)
            if ((k in H) && F[H[k]] != v) { F[H[k]] = v; changed = 1 }
          }
          if (changed) { dirty = 1; print csvjoin(F, n) } else print
          next
        }
        print
      }
      END { exit (dirty ? 0 : 9) }
    ' "$_f" > "$_t"
    if [ $? = 0 ]; then mv "$_t" "$_f"; else rm -f "$_t"; fi
  done
  rm -f "$upd"
  return 0
}

# merge <newcases.csv> -- additive, and never destructive.
#
# Existing ids keep their `status` and `notes` (a verdict and a human comment
# are not the generator's to overwrite) and get the rest of their definition
# refreshed. New ids are appended, with a matching row created in state.csv.
# Nothing is ever dropped, so regeneration is safe to re-run.
cmd_merge() {
  need_csv; need_state
  new="$1"; [ -f "$new" ] || die "merge: no such file: $new"
  tmp="$CSV.tmp.$$"

  # 1. refresh definitions of ids we already have
  awk -v newf="$new" "$AWKLIB"'
    BEGIN {
      KEEP["status"] = 1; KEEP["notes"] = 1
      if ((getline nh < newf) > 0) hdrmap(nh, NH)
      while ((getline l < newf) > 0) {
        csvsplit(l, NF_)
        for (k in NH) NV[NF_[NH["id"]], k] = NF_[NH[k]]
        NIDS[NF_[NH["id"]]] = 1
      }
    }
    NR == 1 { hdrmap($0, H); print; next }
    {
      n = csvsplit($0, F); id = F[H["id"]]
      if (id in NIDS) {
        for (k in H) if (!(k in KEEP) && ((id SUBSEP k) in NV)) F[H[k]] = NV[id, k]
        print csvjoin(F, n); updated++; next
      }
      print; kept++
    }
    END { print "merge: " updated + 0 " updated, " kept + 0 " untouched" > "/dev/stderr" }
  ' "$CSV" > "$tmp" && mv "$tmp" "$CSV"

  # 2. append genuinely new cases, mapping the incoming header onto ours
  awk -v cur="$CSV" -v hdr="$HEADER" "$AWKLIB"'
    BEGIN {
      nh = split(hdr, OUT, ",")
      while ((getline l < cur) > 0) { if (++c == 1) { hdrmap(l, H); continue }
        csvsplit(l, F); HAVE[F[H["id"]]] = 1 }
    }
    NR == 1 { hdrmap($0, NH); next }
    {
      n = csvsplit($0, F); id = F[NH["id"]]
      if (id in HAVE) next
      for (i = 1; i <= nh; i++) R[i] = (OUT[i] in NH) ? F[NH[OUT[i]]] : ""
      if (R[7] == "") R[7] = "new"          # status
      print csvjoin(R, nh)
      added++
    }
    END { print "merge: " added + 0 " added" > "/dev/stderr" }
  ' "$new" >> "$CSV"

  # 3. give every case a state row (bookkeeping the runner will fill in)
  stmp="$STATE.tmp.$$"
  awk -v newf="$new" -v shdr="$STATE_HEADER" "$AWKLIB"'
    BEGIN {
      ns = split(shdr, SC, ",")
      if ((getline nh < newf) > 0) hdrmap(nh, NH)
      while ((getline l < newf) > 0) {
        csvsplit(l, NF_); id = NF_[NH["id"]]
        NIDS[id] = 1
        for (k in NH) NV[id, k] = NF_[NH[k]]
      }
    }
    NR == 1 { hdrmap($0, H); print; next }
    { csvsplit($0, F); SEEN[F[H["id"]]] = 1; print }
    END {
      for (id in NIDS) {
        if (id in SEEN) continue
        for (i = 1; i <= ns; i++) {
          k = SC[i]
          R[i] = (k == "id") ? id : (((id SUBSEP k) in NV) ? NV[id, k] : "")
        }
        if (R[9] == "") R[9] = "0"      # pass_streak
        if (R[10] == "") R[10] = "0"    # flake_count
        print csvjoin(R, ns)
      }
    }
  ' "$STATE" > "$stmp" && mv "$stmp" "$STATE"
}

# next-id <PREFIX>  -> PREFIX-007
cmd_next_id() {
  need_csv
  p="$1"
  awk -v p="$p" "$AWKLIB"'
    NR == 1 { hdrmap($0, H); next }
    { csvsplit($0, F); id = F[H["id"]]
      if (index(id, p "-") == 1) { n = substr(id, length(p) + 2) + 0; if (n > max) max = n } }
    END { printf "%s-%03d\n", p, max + 1 }
  ' "$CSV"
}

cmd_stats() {
  need_csv
  joined | awk "$AWKLIB"'
    NR == 1 { hdrmap($0, H); next }
    { csvsplit($0, F); total++
      st[F[H["status"]]]++; ty[F[H["type"]]]++; pr[F[H["priority"]]]++ }
    END {
      printf "total %d\n", total
      printf "status"; for (k in st) printf " %s=%d", (k == "" ? "new" : k), st[k]; printf "\n"
      printf "type";   for (k in ty) printf " %s=%d", (k == "" ? "page" : k), ty[k]; printf "\n"
      printf "prio";   for (k in pr) printf " %s=%d", k, pr[k]; printf "\n"
    }
  '
}

# prune -- remove cases that say the same thing twice.
# Called automatically after merge, so duplicates never reach the user.
cmd_prune() {
  need_csv
  apply=0; [ "${1:-}" = "--apply" ] && apply=1
  tmp="$CSV.tmp.$$"
  awk -v apply="$apply" "$AWKLIB"'
    NR == 1 { hdrmap($0, H); print; next }
    {
      csvsplit($0, F)
      k = F[H["who"]] "|" F[H["what to do"]] "|" F[H["what should happen"]]
      if (k in seen) { dup++; print "duplicate: " F[H["id"]] " same as " seen[k] > "/dev/stderr"; if (apply) next }
      else seen[k] = F[H["id"]]
      print
    }
    END { print "prune: " dup + 0 " duplicate(s)" > "/dev/stderr" }
  ' "$CSV" > "$tmp"
  if [ "$apply" = "1" ]; then mv "$tmp" "$CSV"; else rm -f "$tmp"; fi
}

# ================================================================= discovery

# routes [srcdir] -- derive the route list from framework file conventions.
# Deterministic; the model is never asked to enumerate what a glob can answer.
cmd_routes() {
  src="${1:-.}"
  {
    # Next.js app router
    find "$src" -type f \( -name 'page.tsx' -o -name 'page.jsx' -o -name 'page.ts' -o -name 'page.js' \) \
      -not -path '*/node_modules/*' 2>/dev/null |
      sed -e 's#.*/app##' -e 's#/page\.[jt]sx\?$##' -e 's#^$#/#' -e 's#(\([^)]*\))/##g'
    # Next.js pages router
    find "$src" -type d -name pages -not -path '*/node_modules/*' 2>/dev/null | while read -r d; do
      find "$d" -type f \( -name '*.tsx' -o -name '*.jsx' \) -not -name '_*' 2>/dev/null |
        sed -e "s#^$d##" -e 's#\.[jt]sx$##' -e 's#/index$##' -e 's#^$#/#'
    done
    # React Router / Vue Router literals
    grep -rhoE "path:[[:space:]]*['\"][^'\"]+['\"]" "$src" \
      --include='*.tsx' --include='*.jsx' --include='*.ts' --include='*.js' --include='*.vue' \
      --exclude-dir=node_modules 2>/dev/null | sed -E "s/.*['\"]([^'\"]+)['\"].*/\1/"
    # Django
    grep -rhoE "path\([[:space:]]*['\"][^'\"]*['\"]" "$src" --include='urls.py' 2>/dev/null |
      sed -E "s/.*['\"]([^'\"]*)['\"].*/\/\1/"
    # Flask / FastAPI
    grep -rhoE "@[a-zA-Z_]+\.(route|get|post|put|delete)\([[:space:]]*['\"][^'\"]+['\"]" "$src" \
      --include='*.py' 2>/dev/null | sed -E "s/.*['\"]([^'\"]+)['\"].*/\1/"
    # Rails
    grep -rhoE "^[[:space:]]*(get|post|put|patch|delete)[[:space:]]+['\"][^'\"]+['\"]" "$src" \
      --include='routes.rb' 2>/dev/null | sed -E "s/.*['\"]([^'\"]+)['\"].*/\/\1/"
    # Spring / .NET attributes
    grep -rhoE "@(Request|Get|Post|Put|Delete)Mapping\([\"']?[^\"')]*" "$src" \
      --include='*.java' 2>/dev/null | sed -E "s/.*[\"']([^\"']*).*/\1/"
    grep -rhoE "\[Route\(\"[^\"]+\"\)\]" "$src" --include='*.cs' 2>/dev/null |
      sed -E 's/.*"([^"]+)".*/\/\1/'
    # Express
    grep -rhoE "(app|router)\.(get|post|put|patch|delete)\([[:space:]]*['\"][^'\"]+['\"]" "$src" \
      --include='*.js' --include='*.ts' --exclude-dir=node_modules 2>/dev/null |
      sed -E "s/.*['\"]([^'\"]+)['\"].*/\1/"
  } 2>/dev/null |
    sed -e 's#//*#/#g' -e 's#\(.\)/$#\1#' |
    grep -E '^/' | grep -vE '\.(css|js|png|svg|ico|map|json)$' |
    # component references, not URLs: a final segment like LoginPage / UserView
    grep -vE '/[A-Z][A-Za-z0-9]*(Page|Component|View|Layout|Screen)$' |
    sort -u
}

# forms [srcdir] -- where forms live, for the page modeller to prioritise.
cmd_forms() {
  src="${1:-.}"
  grep -rlE '<form|onSubmit|handleSubmit|<Form' "$src" \
    --include='*.tsx' --include='*.jsx' --include='*.vue' --include='*.html' \
    --include='*.erb' --include='*.py' --exclude-dir=node_modules 2>/dev/null | sort -u
}

# schemas [srcdir] -- validation constraints, for boundary-case expansion.
cmd_schemas() {
  src="${1:-.}"
  grep -rnE 'z\.(string|number|boolean|enum)\(|\.min\(|\.max\(|\.email\(|\.regex\(' "$src" \
    --include='*.ts' --include='*.tsx' --exclude-dir=node_modules 2>/dev/null
  grep -rnE 'Field\(|constr\(|conint\(|EmailStr|validator' "$src" --include='*.py' 2>/dev/null
  grep -rnE '@(NotNull|NotBlank|Size|Min|Max|Email|Pattern)' "$src" --include='*.java' 2>/dev/null
  grep -rnE '\[(Required|StringLength|Range|EmailAddress|RegularExpression)' "$src" --include='*.cs' 2>/dev/null
}

# hash [srcdir] -- cache key. Changes only when source that could affect the
# UI changes, so an unchanged repo re-generates for free.
cmd_hash() {
  src="${1:-.}"
  if have git && git -C "$src" rev-parse --git-dir >/dev/null 2>&1; then
    { git -C "$src" rev-parse HEAD 2>/dev/null
      git -C "$src" status --porcelain 2>/dev/null
      git -C "$src" diff --stat 2>/dev/null; } | cksum | awk '{print $1}'
  else
    find "$src" -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' \
      -o -name '*.py' -o -name '*.java' -o -name '*.cs' -o -name '*.vue' -o -name '*.html' \) \
      -not -path '*/node_modules/*' -not -path '*/tests/*' 2>/dev/null |
      sort | xargs cksum 2>/dev/null | cksum | awk '{print $1}'
  fi
}

# impacted -- git diff -> case ids, via the source_files column.
cmd_impacted() {
  need_csv
  base="${1:-HEAD}"
  changed="$(git diff --name-only "$base" 2>/dev/null; git diff --name-only --cached 2>/dev/null; git ls-files -o --exclude-standard 2>/dev/null)"
  [ -n "$changed" ] || { echo "impacted: no changed files" >&2; return 0; }
  printf '%s\n' "$changed" | sort -u > "$CACHE/.changed.$$" 2>/dev/null || \
    { mkdir -p "$CACHE"; printf '%s\n' "$changed" | sort -u > "$CACHE/.changed.$$"; }
  joined > "$CACHE/.imp.$$"
  awk -v cf="$CACHE/.changed.$$" "$AWKLIB"'
    BEGIN { while ((getline l < cf) > 0) if (l != "") CH[l] = 1 }
    NR == 1 { hdrmap($0, H); next }
    {
      csvsplit($0, F)
      n = split(F[H["source_files"]], SF, ";")
      for (i = 1; i <= n; i++) {
        if (SF[i] == "") continue
        for (c in CH) if (index(c, SF[i]) > 0 || index(SF[i], c) > 0) { print F[H["id"]]; next }
      }
    }
  ' "$CACHE/.imp.$$" | sort -u
  rm -f "$CACHE/.changed.$$" "$CACHE/.imp.$$"
}

# cover -- discovered routes with no case against them.
cmd_cover() {
  need_csv
  routes_file="${1:-$CACHE/routes.txt}"
  [ -f "$routes_file" ] || die "cover: no route list at $routes_file (run tf.sh routes > $routes_file)"
  joined > "$CACHE/.cover.$$"
  awk "$AWKLIB"'
    NR == FNR { if ($0 != "") R[$0] = 1; next }
    FNR == 1 { hdrmap($0, H); next }
    { csvsplit($0, F); COVERED[F[H["route"]]]++ }
    END {
      for (r in R) if (!(r in COVERED)) print "uncovered\t" r
      for (r in R) if (r in COVERED && COVERED[r] < 2) print "thin\t" r "\t" COVERED[r]
    }
  ' "$routes_file" "$CACHE/.cover.$$" | sort
  rm -f "$CACHE/.cover.$$"
}

# ================================================================ generation

# rbac [routes_file] [privileged_file] [--owner ROLE]
#
# Two sweeps, both written in plain English because a person reads this file:
#   1. nobody (logged out) against every non-public page
#   2. every non-owner role against every restricted page
#
# Which pages are restricted cannot be derived from a glob, so the caller may
# supply a list -- /test-run has the model produce one ONCE from the guards,
# which is a single cheap pass rather than per-case work. With no list, a
# conservative name heuristic is used and says so.
#
# Everything here is `type=page`: a permission check must be judged by what the
# browser actually renders, not by a status code.
cmd_rbac() {
  routes_file="$CACHE/routes.txt"; priv_file=""; owner="admin"
  while [ $# -gt 0 ]; do
    case "$1" in
      --owner) owner="$2"; shift 2 ;;
      *) if [ -z "${_r_set:-}" ]; then routes_file="$1"; _r_set=1; else priv_file="$1"; fi; shift ;;
    esac
  done
  [ -f "$routes_file" ] || die "rbac: no route list at $routes_file"
  [ -f "$CREDS" ] || die "rbac: no $CREDS"
  roles="$(json_keys "$CREDS" roles 2>/dev/null)"
  [ -n "$roles" ] || die "rbac: no roles in $CREDS"

  if [ -n "$priv_file" ] && [ -f "$priv_file" ]; then
    priv="$(cat "$priv_file")"
    echo "rbac: restricted pages from $priv_file" >&2
  else
    priv="$(grep -iE '/(admin|settings|manage|internal|config|users|roles|permissions|billing|audit|reports?|payroll|employees)' "$routes_file" || true)"
    echo "rbac: no restricted-page list given; guessing from names ($(printf '%s' "$priv" | grep -c . ) pages)" >&2
  fi

  # HEADER plus the two state columns merge needs; merge routes each to its file
  printf '%s,type,route,tags\n' "$HEADER"
  n=0; m=0
  while IFS= read -r route; do
    [ -n "$route" ] || continue
    case "$route" in
      /|/login|/signin|/signup|/register|/forgot*|/reset*|/public/*|/health*|/about|/pricing|/terms|/privacy|/apply|/404|/500) continue ;;
      */api/*|/api/*) continue ;;
    esac
    n=$((n + 1))
    probe="$(probe_url "$route")"
    printf 'AUTH-%03d,%s,nobody,%s,%s,high,new,,page,%s,\n' \
      "$n" \
      "$(csv_esc "$(area_of "$route")")" \
      "$(csv_esc "Open $probe without logging in")" \
      "$(csv_esc "Should not open - sends me to the login page")" \
      "$probe"
  done < "$routes_file"

  # API endpoints: no browser, because rendering JSON in Chromium proves
  # nothing. These stay curl cases and stay free.
  a=0
  while IFS= read -r route; do
    case "$route" in /api/*|*/api/*) ;; *) continue ;; esac
    a=$((a + 1))
    probe="$(probe_url "$route")"
    printf 'API-%03d,%s,nobody,%s,%s,high,new,,api,%s,refused\n' \
      "$a" \
      "$(csv_esc "$(area_of "$route")")" \
      "$(csv_esc "Call $probe without logging in")" \
      "$(csv_esc "Should be refused")" \
      "$probe"
  done < "$routes_file"

  [ -n "$priv" ] || return 0
  for role in $roles; do
    [ "$role" = "$owner" ] && continue
    printf '%s
' "$priv" | while IFS= read -r route; do
      [ -n "$route" ] || continue
      case "$route" in */api/*|/api/*) continue ;; esac
      m=$((m + 1))
      probe="$(probe_url "$route")"
      printf 'PERM-%s-%03d,%s,%s,%s,%s,high,new,,page,%s,\n' \
        "$(printf '%s' "$role" | tr 'a-z' 'A-Z' | cut -c1-4)" "$m" \
        "$(csv_esc "$(area_of "$route")")" \
        "$(csv_esc "$(who_label "$role")")" \
        "$(csv_esc "Log in as $(who_label "$role") and open $probe")" \
        "$(csv_esc "Should not open - I am not allowed to see this")" \
        "$probe"
    done
  done
}

# Plain words for roles. "anonymous" means nothing to most readers.
who_label() {
  case "$1" in
    user|member|staff|employee) echo "normal user" ;;
    anonymous|"")               echo "nobody" ;;
    *)                          echo "$1" ;;
  esac
}

# The area column groups cases the way a person would: by the first path
# segment, which is almost always the feature name.
area_of() {
  a="$(printf '%s' "$1" | sed -e 's#^/##' -e 's#/.*$##' -e 's#[^A-Za-z0-9_-].*##')"
  [ -n "$a" ] || a="home"
  printf '%s' "$a"
}

# Parameterised routes cannot be fetched literally. Substitute a probe value so
# the guard is still exercised: an unauthenticated /employees/1 must redirect
# whether or not employee 1 exists.
probe_url() {
  printf '%s' "$1" |
    sed -e 's#:[A-Za-z_][A-Za-z0-9_]*#1#g' \
        -e 's#\[\[\.\.\.[A-Za-z0-9_]*\]\]#1#g' \
        -e 's#\[\.\.\.[A-Za-z0-9_]*\]#1#g' \
        -e 's#\[[A-Za-z0-9_]*\]#1#g' \
        -e 's#<[^>]*>#1#g' \
        -e 's#{[^}]*}#1#g'
}

csv_esc() { printf '%s' "$1" | sed 's/"/""/g' | awk '{ if ($0 ~ /[",]/) printf "\"%s\"", $0; else printf "%s", $0 }'; }

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

# run-api -- execute `type=api` cases with curl.
#
# Only headless endpoints belong here. Anything that renders a page is a
# browser case now, because a permission check has to be judged by what the
# user actually sees: an "Access denied" body served with HTTP 200 passes a
# status-code check and is exactly the bug worth catching.
cmd_run_api() {
  need_csv
  assert_target_allowed
  have curl || die "run-api: curl not found"
  base="$(json_get "$CREDS" base_url)"
  mkdir -p "$RESULTS"
  ts="$(date +%Y%m%d-%H%M%S)"
  out="$RESULTS/run-$ts.csv"
  echo 'id,type,role,route,expected,actual,verdict,ms' > "$out"

  allow_destructive=0
  [ "${1:-}" = "--allow-destructive" ] && allow_destructive=1

  # Tab-separated so the CSV parser, not cut, does the field splitting.
  work="$CACHE/.http.$$"; mkdir -p "$CACHE"
  cmd_select --type api --cols id,type,who,route,tags,status \
    --format plain 2>/dev/null > "$work"

  # Which roles have no session? Cases for those roles are logged-out requests,
  # so a "denied" verdict proves nothing -- they are unverified, not passed.
  # Reporting them as green is the worst failure mode this tool has.
  nosession=""; unverified=0
  for r in $(awk -F"$(printf '\t')" '{print $3}' "$work" | sort -u); do
    case "$r" in ""|anonymous|nobody) continue ;; esac
    [ -f "$TESTS_DIR/.auth/$r.cookies" ] && continue
    nosession="$nosession${nosession:+,}$r"
    unverified=$((unverified + $(awk -F"$(printf '\t')" -v r="$r" '$3==r{n++} END{print n+0}' "$work")))
  done

  run_t0=$(date +%s%N 2>/dev/null || echo 0)
  _tf_progress_init "$(grep -c . "$work" 2>/dev/null || echo 0)"
  skip=0
  while IFS="$(printf '\t')" read -r id typ role route tags status; do
    [ -n "${id:-}" ] || continue
    [ "$status" = "skipped" ] && { skip=$((skip + 1)); _tf_progress_tick SKIP "$typ" "$id"; continue; }
    case "$tags" in
      *destructive*) [ "$allow_destructive" = "1" ] || \
        { skip=$((skip + 1)); _tf_progress_tick SKIP "$typ" "$id"; continue; } ;;
    esac
    [ -n "$route" ] || { _tf_progress_tick SKIP "$typ" "$id"; continue; }

    jar=""
    if [ -n "$role" ] && [ "$role" != "anonymous" ] && [ "$role" != "nobody" ]; then
      [ -f "$TESTS_DIR/.auth/$role.cookies" ] && jar="-b $TESTS_DIR/.auth/$role.cookies"
    fi

    t0=$(date +%s%N 2>/dev/null || echo 0)
    # shellcheck disable=SC2086
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -L --max-redirs 0 \
             $jar "$base$route" 2>/dev/null); [ -n "$code" ] || code=000
    t1=$(date +%s%N 2>/dev/null || echo 0)
    ms=$(( (t1 - t0) / 1000000 ))
    [ "$ms" -lt 0 ] && ms=0

    # `refused` cases assert a denial, so the pass/fail sense is inverted:
    # a 200 on an endpoint that should reject you is the bug being hunted.
    case "$tags" in
      *refused*)
        case "$code" in
          401|403|302|303|307|404) verdict=PASS ;;
          000)                     verdict=ERROR ;;
          2*)                      verdict=FAIL ;;
          *)                       verdict=PASS ;;
        esac ;;
      *)
        case "$code" in
          2*)  verdict=PASS ;;
          000) verdict=ERROR ;;
          *)   verdict=FAIL ;;
        esac ;;
    esac

    printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$id" "$typ" "$role" "$route" "denied-or-2xx" "$code" "$verdict" "$ms" >> "$out"

    _tf_progress_tick "$verdict" "$typ" "$id"
  done < "$work"
  _tf_progress_done
  rm -f "$work"

  # Fold verdicts back into the state columns in a single pass. Per-row `set`
  # would rewrite the whole file once per case.
  now="$(date +%Y-%m-%dT%H:%M:%S)"
  awk -F, -v now="$now" 'NR > 1 {
    print $1 " status=" ($7 == "PASS" ? "passing" : "failing") \
          " last_result=" $7 " last_run=" now
  }' "$out" | cmd_setmany

  run_t1=$(date +%s%N 2>/dev/null || echo 0)
  {
    echo "time=$(date +%H:%M:%S)"
    echo "duration_ms=$(( (run_t1 - run_t0) / 1000000 ))"
    echo "skipped=$skip"
    echo "nosession=$nosession"
    echo "unverified=$unverified"
  } > "${out%.csv}.meta"

  cmd_summary "$out"
}

# cost -- project what a run will spend, by cost tier, before committing to it.
#
# The numbers are deliberately coarse. The point is not an accurate token count,
# it is to make an expensive run visible BEFORE it happens, and to show when a
# generation pass has drifted toward browser cases that a status code could have
# answered.
cmd_cost() {
  need_csv
  budget=0; check=0
  [ "${1:-}" = "--check" ] && check=1
  b="$(json_get "$FRAMEWORK" max_tokens_per_run 2>/dev/null || true)"
  case "$b" in ''|*[!0-9]*) budget=0 ;; *) budget="$b" ;; esac
  joined | awk -v budget="$budget" -v check="$check" "$AWKLIB"'
    function bucket(type, status, spec) {
      if (type == "api")        return "api"
      if (spec != "")           return "spec"
      if (status == "skipped")  return "skip"
      if (status == "passing" || status == "failing") return "replay"
      return "compile"
    }
    NR == 1 { hdrmap($0, H); next }
    {
      csvsplit($0, F)
      b = bucket(F[H["type"]], F[H["status"]], F[H["spec_file"]])
      N[b]++; total++
      if (b == "compile") { r = F[H["route"]]
        if (r != "" && !(r in ROUTE)) { ROUTE[r] = 1; nroutes++ } }
    }
    END {
      cReplay = 350; cCompile = 300; cRoute = 6000
      tReplay = N["replay"] * cReplay; tCompile = N["compile"] * cCompile
      tRoutes = nroutes * cRoute
      grand = tReplay + tCompile + tRoutes

      printf "%-9s %6s  %-34s %10s\n", "BUCKET", "CASES", "ENGINE", "EST TOKENS"
      printf "%-9s %6d  %-34s %10s\n", "api",    N["api"]+0,    "curl, no browser",              "0"
      printf "%-9s %6d  %-34s %10s\n", "spec",   N["spec"]+0,   "your own test runner, headless","0"
      printf "%-9s %6d  %-34s %10d\n", "replay", N["replay"]+0, "browser, replaying a recipe",   tReplay
      printf "%-9s %6d  %-34s %10d\n", "compile",N["compile"]+0,"browser, first time for this case", tCompile
      printf "%-9s %6d  %-34s %10d\n", "pages",  nroutes+0,     "reading a page, once per page", tRoutes
      if (N["skip"] > 0)
        printf "%-9s %6d  %-34s %10s\n", "skipped", N["skip"], "not run", "0"
      printf "%-9s %6d  %-34s %10d\n", "TOTAL", total+0, "", grand

      free = N["api"] + N["spec"]
      freepct = total > 0 ? int(free * 100 / total) : 0
      printf "\n%d of %d cases (%d%%) cost nothing to re-run.\n", free, total, freepct
      if (N["spec"] == 0 && total > 10)
        printf "None are promoted to real test files yet. Once they are, they\nre-run headless for zero tokens - that is the big saving here.\n"
      if (nroutes > 0)
        printf "%d page(s) to read; each is paid once and reused by every case on it.\n", nroutes

      if (budget > 0) {
        printf "\nbudget %d tokens", budget
        if (grand > budget) {
          printf " -- PROJECTION EXCEEDS IT by %d.\n", grand - budget
          printf "Narrow the run (--changed, --feature) or raise\nmax_tokens_per_run in tests/framework.json.\n"
          if (check) exit 1
        } else printf " -- within budget.\n"
      } else if (check)
        printf "\nno max_tokens_per_run set in tests/framework.json; nothing to check.\n"
    }
  '
}

# migrate -- convert an old 20-column testcases.csv into the new pair.
#
# Working suites already exist, so changing the schema without a migration
# would throw away everyone's history. Translates the vocabulary too: P0 ->
# high, anonymous -> nobody, verified/stable -> passing.
cmd_migrate() {
  need_csv
  # The schema may already be current while the *layout* is not -- a suite from
  # before the workbook existed. Adopting it is still a migration.
  head -1 "$CSV" | grep -q '^id,area,who' && {
    echo "migrate: schema already current"
    tf_adopt_workbook
    return 0
  }
  head -1 "$CSV" | grep -q '^id,feature,role' || die "migrate: unrecognised header; expected the old 20-column format"

  cp "$CSV" "$CSV.old" || die "migrate: could not back up $CSV"
  mkdir -p "$CACHE"
  tmp="$CSV.new.$$"; stmp="$STATE.new.$$"

  awk -v hdr="$HEADER" -v shdr="$STATE_HEADER" -v stf="$stmp" "$AWKLIB"'
    function who(r)   { return (r == "anonymous" || r == "") ? "nobody" :
                               ((r == "user") ? "normal user" : r) }
    function prio(p)  { return (p == "P0") ? "high" : ((p == "P1") ? "medium" :
                               ((p == "P2") ? "low" : (p == "" ? "medium" : p))) }
    function stat(s)  { return (s == "verified" || s == "stable") ? "passing" :
                               ((s == "new" || s == "") ? "new" : s) }
    function kind(t)  { return (t == "api") ? "api" : "page" }
    BEGIN { nh = split(hdr, OUT, ","); ns = split(shdr, SC, ",")
            print hdr; print shdr > stf }
    NR == 1 { hdrmap($0, H); next }
    {
      n = csvsplit($0, F)
      R[1] = F[H["id"]]
      R[2] = F[H["feature"]]
      R[3] = who(F[H["role"]])
      R[4] = F[H["steps"]]
      R[5] = F[H["expected"]]
      R[6] = prio(F[H["priority"]])
      R[7] = stat(F[H["status"]])
      R[8] = F[H["notes"]]
      print csvjoin(R, nh)

      S[1] = F[H["id"]];          S[2] = kind(F[H["type"]])
      S[3] = F[H["route"]];       S[4] = F[H["tags"]]
      S[5] = F[H["source_files"]];S[6] = F[H["spec_file"]]
      S[7] = F[H["last_run"]];    S[8] = F[H["last_result"]]
      S[9] = (F[H["pass_streak"]] == "" ? "0" : F[H["pass_streak"]])
      S[10] = (F[H["flake_count"]] == "" ? "0" : F[H["flake_count"]])
      S[11] = F[H["viewport"]]
      print csvjoin(S, ns) > stf
      moved++
    }
    END { print "migrate: " moved + 0 " cases moved" > "/dev/stderr" }
  ' "$CSV" > "$tmp" && mv "$tmp" "$CSV" && mv "$stmp" "$STATE"
  echo "migrate: old file kept at $CSV.old"
  tf_adopt_workbook
}

# Move a pre-workbook suite to the new layout: the xlsx becomes the store and
# the CSV moves out of sight into .cache/. Only on an explicit `migrate` -- a
# file a person has been opening for months should not relocate itself as a side
# effect of some other command.
tf_adopt_workbook() {
  [ -f "$TESTS_DIR/testcases.csv" ] || return 0
  tf_python >/dev/null 2>&1 || {
    echo "migrate: no python here, so the suite stays at $TESTS_DIR/testcases.csv" >&2
    return 0
  }
  mkdir -p "$CACHE"
  mv "$TESTS_DIR/testcases.csv" "$CACHE/testcases.csv" || return 0
  CSV="$CACHE/testcases.csv"
  cmd_xlsx || true
  echo "migrate: the store is now $XLSX; the engine's CSV moved to $CSV"
}

# cache-check <srcdir> -- is the discovery cache still valid?
#
# Exit 0 means unchanged, so /test-run can reuse the cached feature map and
# page models for free. Exit 1 means the source moved and they must be rebuilt.
# This was previously only an instruction in a skill, which meant a model that
# skipped the instruction silently re-paid full price.
cmd_cache_check() {
  src="${1:-.}"
  mkdir -p "$CACHE"
  now="$(cmd_hash "$src")"
  old=""
  [ -f "$CACHE/hash" ] && old="$(cat "$CACHE/hash" 2>/dev/null)"
  if [ -n "$old" ] && [ "$old" = "$now" ]; then
    echo "cache: valid ($now) -- reuse .cache/, regeneration is free"
    return 0
  fi
  printf '%s\n' "$now" > "$CACHE/hash"
  if [ -z "$old" ]; then echo "cache: cold ($now) -- first run, nothing cached yet"
  else echo "cache: stale ($old -> $now) -- source changed, rebuild what it affects"; fi
  return 1
}

# ================================================================== reporting

# junit <results.xml> [out.csv] -- JUnit XML -> results CSV.
#
# The Tier 2 fallback. A project whose stack has its own adapter in templates/
# should use that one, since it runs on a runtime the project already has. This
# exists so a project WITHOUT a usable adapter still gets machine-readable
# results instead of the model reading XML.
#
# The case id is recovered from the test name, which codegen stamps there.
cmd_junit() {
  xml="${1:?junit: results.xml required}"
  [ -f "$xml" ] || die "junit: no such file: $xml"
  out="${2:-}"
  { echo 'id,type,role,route,expected,actual,verdict,ms'
    # Normalise to one <testcase> per line first, so the parse stays line-based.
    tr '\n' ' ' < "$xml" |
      sed -e 's#<testcase#\n<testcase#g' -e 's#</testsuite#\n</testsuite#g' |
      awk '
        /^<testcase/ {
          name = ""; if (match($0, /name="[^"]*"/)) name = substr($0, RSTART+6, RLENGTH-7)
          t = 0;     if (match($0, /time="[^"]*"/)) t = substr($0, RSTART+6, RLENGTH-7) + 0

          # id conventions: hyphenated (JS) or underscored (python/java/dotnet)
          id = ""
          if (match(name, /[A-Z][A-Z0-9]*(-[A-Z][A-Z0-9]*)*-[0-9]+/)) id = substr(name, RSTART, RLENGTH)
          else if (match(name, /[A-Z][A-Z0-9]*(_[A-Z][A-Z0-9]*)*__[0-9]+/)) {
            id = substr(name, RSTART, RLENGTH); gsub(/_+/, "-", id)
          }
          if (id == "") next          # not one of ours; skip rather than guess

          verdict = "PASS"; msg = "ok"
          if ($0 ~ /<skipped/) { verdict = "SKIP"; msg = "skipped" }
          else if ($0 ~ /<error/)   { verdict = "ERROR"; msg = "error" }
          else if ($0 ~ /<failure/) { verdict = "FAIL";  msg = "failed" }
          if ((verdict == "FAIL" || verdict == "ERROR") &&
              match($0, /<(failure|error)[^>]*message="[^"]*"/)) {
            m = substr($0, RSTART, RLENGTH)
            if (match(m, /message="[^"]*"/)) msg = substr(m, RSTART+9, RLENGTH-10)
          }
          gsub(/&quot;/, "\"", msg); gsub(/&amp;/, "\\&", msg)
          gsub(/&lt;/, "<", msg);    gsub(/&gt;/, ">", msg)
          if (msg ~ /[",]/) { gsub(/"/, "\"\"", msg); msg = "\"" msg "\"" }

          printf "%s,ui,,,,%s,%s,%d\n", id, msg, verdict, t * 1000
        }'
  } | if [ -n "$out" ]; then cat > "$out"; echo "junit: wrote $out" >&2; else cat; fi
}

# diff <old.csv> <new.csv> -- regressions and fixes only. The model is never
# shown a passing row.
cmd_diff() {
  old="$1"; new="$2"
  [ -f "$old" ] || die "diff: no such file: $old"
  [ -f "$new" ] || die "diff: no such file: $new"
  awk -F, '
    NR == FNR { if (FNR > 1) O[$1] = $7; next }
    FNR == 1 { next }
    {
      if (!($1 in O)) { print "NEW\t" $1 "\t" $7; next }
      if (O[$1] != $7) {
        if ($7 == "PASS") print "FIXED\t" $1 "\t" O[$1] " -> PASS"
        else print "REGRESSED\t" $1 "\t" O[$1] " -> " $7
      }
    }
  ' "$old" "$new" | sort
}

cmd_latest() { ls -1t "$RESULTS"/run-*.csv 2>/dev/null | head -n "${1:-1}"; }

# summary [results.csv] [--json|--quiet] [--ascii] [--color|--no-color]
#
# The end-of-run dashboard. Rendered here, from the results CSV, at zero model
# tokens -- callers print it verbatim rather than describing it again.
#
# Layout note: awk counts bytes, not characters, so every symbol is laid out as
# a one-byte placeholder and substituted for UTF-8 only after padding is
# computed. Colour codes are zero-width and excluded from the length.
cmd_summary() {
  res=""; want_json=0; quiet=0; ascii="${TF_ASCII:-0}"; color=auto
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) want_json=1; shift ;;
      --quiet) quiet=1; shift ;;
      --ascii) ascii=1; shift ;;
      --color) color=always; shift ;;
      --no-color) color=never; shift ;;
      *) res="$1"; shift ;;
    esac
  done
  [ -n "$res" ] || res="$(cmd_latest 1)"
  [ -n "$res" ] && [ -f "$res" ] || { echo "summary: no results yet -- run /test-run first" >&2; return 3; }

  # Diff against the previous run only when summarising the newest one.
  prev=""
  [ "$res" = "$(cmd_latest 1)" ] && prev="$(ls -1t "$RESULTS"/run-*.csv 2>/dev/null | sed -n '2p')"
  meta="${res%.csv}.meta"; [ -f "$meta" ] || meta=/dev/null

  usecolor=0
  case "$color" in
    always) usecolor=1 ;;
    auto) if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != dumb ]; then usecolor=1; fi ;;
  esac

  width="${COLUMNS:-}"
  [ -n "$width" ] || width="$(tput cols 2>/dev/null || echo 72)"
  case "$width" in ''|*[!0-9]*) width=72 ;; esac
  [ "$width" -gt 78 ] && width=78
  [ "$width" -lt 34 ] && width=34

  # Pass rate of the last 10 runs, oldest first, for the sparkline.
  trend=""
  for f in $(ls -1t "$RESULTS"/run-*.csv 2>/dev/null | head -10 |
             awk '{a[NR]=$0} END{for(i=NR;i>=1;i--) print a[i]}'); do
    trend="$trend$(awk -F, 'NR>1{t++; if($7=="PASS")p++} END{printf "%d", (t?int(p*100/t):0)}' "$f"),"
  done

  # Placeholder bytes, chosen so none can occur in a route, id or status code:
  #   01 TL  02 TR  03 hbar  04 side  05 BL  06 BR
  #   07 check  08 cross  0B circle  0C warn  0E bolt  0F arrow
  #   10-15 sparkline levels   16 bar-full  17 bar-empty
  #   18 reset  19 green  1A red  1C yellow  1D dim  1E bold  1F cyan
  awk -F, -v prev="$prev" -v metaf="$meta" -v W="$width" -v JSON="$want_json" \
      -v QUIET="$quiet" -v TREND="$trend" -v RESF="$res" -v PROJ="$(basename "$(pwd)")" '
  function vlen(s,   i, n, c) {
    n = 0
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (c == "\030" || c == "\031" || c == "\032" || c == "\034" ||
          c == "\035" || c == "\036" || c == "\037") continue
      n++
    }
    return n
  }
  function pad(s, w,   d) { d = w - vlen(s); return d > 0 ? s sprintf("%" d "s", "") : s }
  function rep(c, n,   i, s) { s = ""; for (i = 0; i < n; i++) s = s c; return s }
  # Clip to a visible width, keeping zero-width colour markers so nothing leaks.
  function trunc(s, w,   i, n, c, out) {
    if (vlen(s) <= w) return s
    n = 0; out = ""
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (c == "\030" || c == "\031" || c == "\032" || c == "\034" ||
          c == "\035" || c == "\036" || c == "\037") { out = out c; continue }
      if (n >= w - 1) break
      out = out c; n++
    }
    return out "\030"
  }
  function row(s) { LINES[++NL] = "\004" pad(trunc(s, INNER), INNER) "\004" }
  function sect(s) { LINES[++NL] = s }

  BEGIN { INNER = W - 2; split(TREND, TR, ",") }

  # results columns: id,type,role,route,expected,actual,verdict,ms
  NR > 1 && NF >= 7 {
    id = $1; type = $2; role = $3; route = $4; actual = $6; verdict = $7
    total++; V[verdict]++; TT[type]++
    if (verdict == "PASS") { TP[type]++; PASSED[id] = 1 }
    else {
      FAILN++
      if (!FIRSTFAIL) FIRSTFAIL = id
      # A case whose id says AUTH/PERM asserts that someone should be kept out.
      # Failing it means they are not being kept out -- which outranks every
      # broken button, so it is pinned above the ordinary failures.
      if (id ~ /^(AUTH|PERM)-/) {
        NSEC++; SECID[NSEC] = id
        SEC[NSEC] = sprintf("%-15s %-11s \017 %-20s", id, \
                            (role == "" ? "nobody" : role), route)
        SECC[NSEC] = actual
      } else {
        NOTH++; OTHID[NOTH] = id
        OTH[NOTH] = sprintf("%-15s %-32s", id, route)
        OTHC[NOTH] = actual
      }
    }
    if (type == "api") FREE++
    dur += $8 + 0
    next
  }

  END {
    while ((getline l < metaf) > 0) {
      if (index(l, "=") == 0) continue
      META[substr(l, 1, index(l, "=") - 1)] = substr(l, index(l, "=") + 1)
    }
    if (META["duration_ms"] != "") dur = META["duration_ms"]
    skipped = META["skipped"] + 0
    nosession = META["nosession"]
    unver = META["unverified"] + 0

    if (prev != "") {
      while ((getline l < prev) > 0) { if (++pc == 1) continue
        split(l, P, ","); PREVV[P[1]] = P[7] }
    }

    pct = total > 0 ? int(V["PASS"] * 100 / total) : 0

    if (JSON) {
      printf "{\"run\":\"%s\",\"total\":%d,\"pass\":%d,\"fail\":%d,\"error\":%d,\"skipped\":%d,", \
             RESF, total, V["PASS"]+0, V["FAIL"]+0, V["ERROR"]+0, skipped
      printf "\"pass_rate\":%d,\"security_failures\":%d,\"free_cases\":%d,\"duration_ms\":%d,", \
             pct, NSEC+0, FREE+0, dur
      printf "\"unverified_cases\":%d,\"unverified_roles\":\"%s\"}\n", unver, nosession
      exit
    }
    if (QUIET) {
      printf "%s %d/%d cases (%d%%)%s\n", \
             (NSEC > 0 ? "SECURITY" : (FAILN > 0 ? "FAIL" : "PASS")), \
             V["PASS"]+0, total, pct, \
             (NSEC > 0 ? sprintf(" - %d privilege boundary crossed", NSEC) : "")
      exit
    }

    # ---------------------------------------------------------------- panel
    compact = (INNER < 56)
    hdr = "\003 TEST RUN \003\003 " PROJ " "
    stamp = (META["time"] != "") ? "\003 " META["time"] " " : ""
    d = INNER - vlen(hdr) - vlen(stamp)
    if (d < 1) { stamp = ""; d = INNER - vlen(hdr); if (d < 1) d = 1 }
    LINES[++NL] = "\001" hdr rep("\003", d) stamp "\002"

    if (!compact) row("")

    barw = compact ? 10 : 20
    filled = int(pct * barw / 100)
    bar = rep("\026", filled) rep("\027", barw - filled)
    ratecol = (NSEC > 0) ? "\032" : (pct == 100 ? "\031" : "\034")
    row(sprintf("  \036%d cases\030   %s  %s%d%%\030   \035%.1fs\030", \
        total, bar, ratecol, pct, dur / 1000))
    if (!compact) row("")

    if (compact)
      row(sprintf("  \031\007%d\030 \032\010%d\030 \034!%d\030 \035\013%d\030", \
          V["PASS"]+0, V["FAIL"]+0, V["ERROR"]+0, skipped))
    else
      row(sprintf("  \031\007 pass %-4d\030 \032\010 fail %-4d\030 \034! error %-3d\030 \035\013 skip %-3d\030", \
          V["PASS"]+0, V["FAIL"]+0, V["ERROR"]+0, skipped))
    if (!compact) row("")

    tl = "  "
    for (t in TT) tl = tl sprintf("%s %d/%d    ", t, TP[t]+0, TT[t])
    if (length(tl) > 2 && !compact) row(tl)

    if (FREE > 0) {
      if (compact) row(sprintf("  \034\016\030 \035%d/%d free\030", FREE, total))
      else row(sprintf("  \034\016\030 \035%d of %d ran free (curl); the rest used a browser\030", FREE, total))
    }

    ntr = 0
    for (i = 1; (i in TR) && TR[i] != ""; i++) ntr = i
    if (ntr >= 2 && !compact) {
      sp = ""
      for (i = 1; i <= ntr; i++) {
        lvl = int(TR[i] * 5 / 100); if (lvl > 5) lvl = 5
        sp = sp sprintf("%c", 16 + lvl)
      }
      row(sprintf("  \035trend\030  %s  \035%d%%\030", sp, TR[ntr]))
    }

    LINES[++NL] = "\005" rep("\003", INNER) "\006"

    # ------------------------------------------------------------- sections
    if (NSEC > 0) {
      sect("")
      sect("  \032\036\014  SECURITY - privilege boundary crossed\030")
      for (i = 1; i <= NSEC && i <= 8; i++)
        sect(sprintf("     \032%s\030 \035%s%s\030", SEC[i], SECC[i], \
             ((SECID[i] in PREVV) && PREVV[SECID[i]] == "PASS" ? "  (new since last run)" : "")))
      if (NSEC > 8) sect(sprintf("     \035... and %d more\030", NSEC - 8))
    }

    nreg = 0
    for (i = 1; i <= NOTH; i++)
      if ((OTHID[i] in PREVV) && PREVV[OTHID[i]] == "PASS") { nreg++; REG[nreg] = i }
    for (i = 1; i <= NSEC; i++)
      if ((SECID[i] in PREVV) && PREVV[SECID[i]] == "PASS") nsecreg++

    if (nreg > 0) {
      sect("")
      n = split(prev, PP, "/")
      sect(sprintf("  \034\036REGRESSED\030 \035since %s\030", PP[n]))
      for (i = 1; i <= nreg && i <= 8; i++)
        sect(sprintf("     \034%s\030  \035%s\030", OTH[REG[i]], OTHC[REG[i]]))
    }

    shown = 0
    for (i = 1; i <= NOTH; i++) {
      if ((OTHID[i] in PREVV) && PREVV[OTHID[i]] == "PASS") continue
      if (shown == 0) { sect(""); sect("  \036FAILED\030") }
      if (shown < 8) sect(sprintf("     \032%s\030  \035%s\030", OTH[i], OTHC[i]))
      shown++
    }
    if (shown > 8) sect(sprintf("     \035... and %d more\030", shown - 8))

    nfix = 0
    for (id in PREVV) if (PREVV[id] != "PASS" && (id in PASSED)) { nfix++; FIX[nfix] = id }
    if (nfix > 0) {
      sect(""); sect("  \031\036FIXED\030")
      line = "     \031"
      for (i = 1; i <= nfix && i <= 10; i++) line = line FIX[i] "  "
      sect(line "\030")
    }

    # ---- false-green guards: silence here would read as coverage
    warned = 0
    if (nosession != "") {
      sect(""); warned = 1
      sect(sprintf("  \034\014  %d case%s ran with no session for [%s]\030", unver, (unver==1?"":"s"), nosession))
      sect("     \035logged-out requests are denied anyway, so these verdicts are\030")
      sect("     \035unverified, not passed - run /test-setup to fix\030")
    }
    if (skipped > 0) {
      if (!warned) sect("")
      sect(sprintf("  \034\014  %d destructive case%s skipped\030 \035(--allow-destructive to run)\030", \
           skipped, (skipped == 1 ? "" : "s")))
    }

    # ---- exactly one next action, chosen by outcome
    sect("")
    sect(sprintf("  \035\017 %s\030", RESF))
    if (NSEC > 0)          nxt = "/test-report --bug " SECID[1]
    else if (nosession != "") nxt = "/test-setup"
    else if (nreg > 0)     nxt = "/test-run --only-failing"
    else if (FAILN > 0)    nxt = "/test-report"
    else                   nxt = "/test-report --publish"
    sect(sprintf("  \037\017 %s\030", nxt))

    for (i = 1; i <= NL; i++) print LINES[i]
  }
  ' "$res" | _tf_render "$ascii" "$usecolor"

  # Exit status, for CI gating. Recomputed rather than smuggled through the pipe.
  awk -F, 'NR>1 && NF>=7 {
             if ($7 != "PASS") { f++; if ($2 == "rbac" || $2 == "auth") s++ }
           }
           END { exit (s > 0 ? 2 : (f > 0 ? 1 : 0)) }' "$res"
}

# Substitute layout placeholders for real glyphs and colour. Split from the awk
# so that stays about layout and this stays about presentation.
_tf_render() {
  _a="$1"; _c="$2"
  if [ "$_a" = "1" ]; then
    sed -e 's/\x01/+/g' -e 's/\x02/+/g' -e 's/\x03/-/g' -e 's/\x04/|/g' \
        -e 's/\x05/+/g' -e 's/\x06/+/g' \
        -e 's/\x07/+/g' -e 's/\x08/x/g' -e 's/\x0b/o/g' -e 's/\x0c/!/g' \
        -e 's/\x0e/*/g' -e 's/\x0f/>/g' \
        -e 's/\x16/#/g'  -e 's/\x17/./g' \
        -e 's/\x10/_/g;s/\x11/./g;s/\x12/-/g;s/\x13/+/g;s/\x14/*/g;s/\x15/#/g'
  else
    sed -e 's/\x01/╭/g' -e 's/\x02/╮/g' -e 's/\x03/─/g' -e 's/\x04/│/g' \
        -e 's/\x05/╰/g' -e 's/\x06/╯/g' \
        -e 's/\x07/✓/g' -e 's/\x08/✗/g' -e 's/\x0b/○/g' -e 's/\x0c/⚠/g' \
        -e 's/\x0e/⚡/g' -e 's/\x0f/→/g' \
        -e 's/\x16/█/g' -e 's/\x17/░/g' \
        -e 's/\x10/▁/g;s/\x11/▃/g;s/\x12/▄/g;s/\x13/▅/g;s/\x14/▆/g;s/\x15/█/g'
  fi | if [ "$_c" = "1" ]; then
    sed -e 's/\x18/\x1b[0m/g'  -e 's/\x19/\x1b[32m/g' -e 's/\x1a/\x1b[31m/g' \
        -e 's/\x1c/\x1b[33m/g' -e 's/\x1d/\x1b[2m/g'  -e 's/\x1e/\x1b[1m/g' \
        -e 's/\x1f/\x1b[36m/g'
  else
    sed -e 's/\x18//g' -e 's/\x19//g' -e 's/\x1a//g' -e 's/\x1c//g' \
        -e 's/\x1d//g' -e 's/\x1e//g' -e 's/\x1f//g'
  fi
}

cmd_render() {
  res="${1:-$(cmd_latest 1)}"
  [ -n "$res" ] && [ -f "$res" ] || die "render: no results file"
  out="${2:-$RESULTS/report.html}"
  awk -F, -v title="$(basename "$res")" '
    NR == 1 { next }
    { total++; v[$7]++; if ($7 != "PASS") { rows = rows sprintf("<tr class=f><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>", $1, $2, $4, $6, $7) } }
    END {
      printf "<!doctype html><meta charset=utf-8><title>Test results %s</title>", title
      printf "<style>body{font:14px system-ui;margin:2rem;max-width:60rem}h1{font-size:1.3rem}"
      printf ".s{display:flex;gap:1rem;margin:1rem 0}.s div{padding:.6rem 1rem;border-radius:.4rem;background:#f2f2f2}"
      printf ".p{background:#e6f6e9}.f{background:#fdecea}table{border-collapse:collapse;width:100%%}"
      printf "td,th{border-bottom:1px solid #ddd;padding:.4rem .6rem;text-align:left;font-size:13px}</style>"
      printf "<h1>Test results <small>%s</small></h1><div class=s>", title
      printf "<div class=p>PASS %d</div>", v["PASS"] + 0
      printf "<div class=f>FAIL %d</div>", v["FAIL"] + 0
      printf "<div>ERROR %d</div><div>total %d</div></div>", v["ERROR"] + 0, total
      if (rows == "") printf "<p>All %d cases passed.</p>", total
      else printf "<table><tr><th>id<th>type<th>route<th>actual<th>verdict</tr>%s</table>", rows
    }
  ' "$res" > "$out"
  echo "$out"
}

# ======================================================================= main

# version -- print the plugin version.
#
# The version lives in exactly one place, .claude-plugin/plugin.json. Resolve it
# from this script's own location, so it works whether tf.sh was invoked through
# $CLAUDE_PLUGIN_ROOT, by an absolute path, or from a checkout. Unknown is an
# answer; failing is not -- this exists to make a bug report answerable.
cmd_version() {
  root="${CLAUDE_PLUGIN_ROOT:-}"
  [ -n "$root" ] || root="$(CDPATH= cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd)"
  v="$(json_get "$root/.claude-plugin/plugin.json" version 2>/dev/null)"
  [ -n "$v" ] || v=unknown
  echo "tf.sh $v"
}

# xlsx [--import|--status] -- the Excel side.
#
# tests/testcases.xlsx is the store: flows, cases and their statuses. This is the
# bridge to it, and scripts/tf-xlsx.py is the only thing that touches the file.
#
#   (no flag)  rebuild every sheet from the CSV, flows.txt and the last run
#   --import   pull the sheet back in: hand edits win, new rows get ids
#   --status   write verdicts back after a run, and roll each flow up
#
# Writing a .xlsx needs an interpreter, so a machine without one gets a line on
# stderr and exit 0 -- never a failed run. The CSV is still correct there.
# Verify, never infer -- the same rule stack detection follows. On Windows,
# `python3` is usually an App Execution Alias that resolves on PATH, prints an
# advert for the Microsoft Store and exits 49. `have` is therefore not enough:
# make each candidate prove it can run before believing in it.
tf_python() {
  for _c in python3 python py; do
    if have "$_c" && "$_c" -c 'import sys, zipfile' >/dev/null 2>&1; then
      echo "$_c"; return 0
    fi
  done
  return 1
}

tf_xlsx_script() {
  root="${CLAUDE_PLUGIN_ROOT:-}"
  [ -n "$root" ] || root="$(CDPATH= cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd)"
  echo "$root/scripts/tf-xlsx.py"
}

cmd_xlsx() {
  mode=export
  case "${1:-}" in
    --import) mode=import ;;
    --status) mode=status ;;
    ""|--export) mode=export ;;
    *) die "xlsx: unknown option $1 (use --import or --status)" ;;
  esac

  py="$(tf_python)"
  script="$(tf_xlsx_script)"
  if [ -z "$py" ] || [ ! -f "$script" ]; then
    echo "xlsx: no python on PATH -- the workbook is not maintained here; $CSV is current" >&2
    return 0
  fi

  need_csv
  mkdir -p "$CACHE"
  joined="$CACHE/.xlsx-cases.$$"
  cmd_select --cols id,area,who,todo,expect,priority,status,notes,route,tags,viewport,last_run,last_result \
             --format csv > "$joined" 2>/dev/null || : > "$joined"
  flows="$CACHE/flows.txt"
  latest="$(cmd_latest 1 2>/dev/null | head -1)"

  rc=0
  case "$mode" in
    export|status)
      "$py" "$script" "$( [ "$mode" = status ] && echo status || echo export )" \
        --xlsx "$XLSX" --cases "$joined" --flows "$flows" --results "$latest" || rc=$?
      ;;
    import)
      if [ ! -f "$XLSX" ]; then
        echo "xlsx: no $XLSX yet, nothing to import" >&2
        rm -f "$joined"; return 0
      fi
      newf="$CACHE/.xlsx-new.$$"; humanf="$CACHE/.xlsx-human.$$"
      if "$py" "$script" import --xlsx "$XLSX" --cases "$joined" \
           --out-human "$humanf" --out-new "$newf"; then
        # New rows first, so state.csv gains their bookkeeping, then the human
        # columns wholesale -- the sheet is the source of truth for those.
        if [ "$(wc -l < "$newf" 2>/dev/null || echo 1)" -gt 1 ]; then
          cmd_merge "$newf" >&2 || rc=$?
        fi
        cp "$humanf" "$CSV" || rc=$?
      else
        rc=$?
      fi
      rm -f "$newf" "$humanf"
      ;;
  esac
  rm -f "$joined"
  return $rc
}

usage() {
  cat <<'EOF'
tf.sh - deterministic engine for the Claude test framework

CSV        init-csv | select | set | setmany | merge | next-id | stats | prune | migrate
excel      xlsx [--import|--status]
discovery  routes | forms | schemas | hash | cache-check | impacted | cover
generate   rbac
execute    login | storage-state | preflight | run-api
report     summary | watch | cost | diff | junit | render | latest
meta       version | help

  select --status new --priority high --who nobody --area admin \
         --cols id,todo,route --limit 20 --count --format plain
  set AUTH-002 status=failing notes="shows the page to everyone"
  merge /tmp/new-cases.csv        additive; never overwrites status or notes
  migrate                         convert an old 20-column suite
  routes src/ > tests/.cache/routes.txt
  rbac tests/.cache/routes.txt > /tmp/rbac.csv
  run-api [--allow-destructive]
  storage-state admin            cookie jar -> Playwright storage state
  xlsx                           rebuild tests/testcases.xlsx
  xlsx --import                  pull hand edits back out of the sheet
  xlsx --status                  write verdicts back after a run

Two files: tests/testcases.csv is the 8 plain columns a person reads;
tests/.cache/state.csv is the bookkeeping. `select` joins them for you.

Never `cat` testcases.csv. Query it.
EOF
}

# tf_auto_migrate -- bring an older suite up to date without being asked.
#
# Two things can be out of date: the schema (the old 20-column testcases.csv)
# and the layout (a top-level CSV from before the workbook existed). Both are
# handled here, once, before the subcommand runs, so nobody has to know that
# `migrate` exists. Safe on a current suite: it reads one header line and
# returns. Set TF_NO_AUTO_MIGRATE=1 to hold a suite exactly where it is.
tf_auto_migrate() {
  [ "${TF_NO_AUTO_MIGRATE:-}" = "1" ] && return 0
  [ -f "$CSV" ] || return 0

  # Old schema. cmd_migrate backs up to .old, converts, and adopts the workbook.
  if head -1 "$CSV" 2>/dev/null | grep -q '^id,feature,role'; then
    echo "tf: this suite uses the old format -- migrating it now" >&2
    cmd_migrate >&2 || true
    return 0
  fi

  # Current schema, old layout: the CSV is still at the top level.
  case "$CSV" in
    "$TESTS_DIR/testcases.csv") tf_adopt_workbook >&2 || true ;;
  esac
  return 0
}

[ $# -gt 0 ] || { usage; exit 0; }
sub="$1"; shift

# Housekeeping first -- except for the two subcommands that answer without
# touching a suite at all.
case "$sub" in
  help|-h|--help|version|-v|--version) ;;
  *) tf_auto_migrate ;;
esac

case "$sub" in
  init-csv)  cmd_init_csv "$@" ;;
  select)    cmd_select "$@" ;;
  set)       cmd_set "$@" ;;
  setmany)   cmd_setmany "$@" ;;
  merge)     cmd_merge "$@" ;;
  next-id)   cmd_next_id "$@" ;;
  stats)     cmd_stats "$@" ;;
  prune)     cmd_prune "$@" ;;
  routes)    cmd_routes "$@" ;;
  forms)     cmd_forms "$@" ;;
  schemas)   cmd_schemas "$@" ;;
  hash)      cmd_hash "$@" ;;
  impacted)  cmd_impacted "$@" ;;
  cover)     cmd_cover "$@" ;;
  cost)      cmd_cost "$@" ;;
  cache-check) cmd_cache_check "$@" ;;
  migrate)   cmd_migrate "$@" ;;
  rbac)      cmd_rbac "$@" ;;
  login)     cmd_login "$@" ;;
  storage-state) cmd_storage_state "$@" ;;
  xlsx)      cmd_xlsx "$@" ;;
  preflight) cmd_preflight "$@" ;;
  run-api)   cmd_run_api "$@" ;;
  junit)     cmd_junit "$@" ;;
  diff)      cmd_diff "$@" ;;
  render)    cmd_render "$@" ;;
  summary)   cmd_summary "$@" ;;
  watch)     cmd_watch "$@" ;;
  latest)    cmd_latest "$@" ;;
  version|-v|--version) cmd_version ;;
  help|-h|--help) usage ;;
  *) die "unknown subcommand: $sub (try: tf.sh help)" ;;
esac
