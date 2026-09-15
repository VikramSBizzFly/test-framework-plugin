# shellcheck shell=sh
# lib/progress.sh -- the progress bar and `watch`
#
# Sourced by scripts/tf.sh; defines functions only. See tf.sh for the paths
# and schema variables these rely on.

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
