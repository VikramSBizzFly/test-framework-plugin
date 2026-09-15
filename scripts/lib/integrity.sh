# shellcheck shell=sh
# lib/integrity.sh -- keeping the case store readable: validate, commit, back
# up, check, restore.
#
# Sourced by scripts/tf.sh; defines functions only. See tf.sh for the paths
# and schema variables these rely on.
#
# The store is two CSV files that awk reads line by line. One row that gains or
# loses a field shifts every column after it, and nothing downstream can tell --
# a verdict lands in `notes`, a route lands in `tags`. So the rule is: no file
# replaces a store file unless it parses, every write keeps a copy of what it
# wrote, and a store that stops parsing stops the engine instead of being read.

BACKUPS="$CACHE/backups"
BACKUP_KEEP=10
BACKUP_EVERY_MIN=10   # at most one timestamped copy per file per ten minutes

# _tf_validate <file> [header] -- exit 0 if the file is a well-formed store file.
#
# Well-formed means: a known header (testcases.csv must match HEADER exactly; a
# state file must start with `id,type,route`), every row has as many fields as
# the header, and no quote is left open at the end of a line (which is what a
# multi-line record, or a half-quoted field, looks like to a line reader).
# Problems go to stderr, at most five, each with its line number. Passing a
# header accepts that header instead of HEADER.
_tf_validate() {
  awk -v hdr="${2:-$HEADER}" "$AWKLIB"'
    function report(msg) { bad++; if (bad <= 5) print "  line " NR ": " msg > "/dev/stderr" }
    # field count, and whether a quote is still open at the end of the line
    function count(line,   i, c, n, inq) {
      n = 1; inq = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (c == "\"") { if (inq && substr(line, i+1, 1) == "\"") i++; else inq = !inq }
        else if (c == "," && !inq) n++
      }
      OPEN = inq
      return n
    }
    { sub(/\r$/, "") }
    NR == 1 {
      want = count($0)
      if ($0 != hdr && index($0, "id,type,route") != 1)
        report("unrecognised header: " substr($0, 1, 60))
      next
    }
    $0 == "" { next }
    {
      n = count($0)
      if (OPEN) report("a quote is never closed (a line break inside a field?): " substr($0, 1, 60))
      else if (n != want) report("expected " want " fields, got " n ": " substr($0, 1, 60))
    }
    END {
      if (NR == 0) report("empty file")
      if (bad > 5) print "  ... and " bad - 5 " more" > "/dev/stderr"
      exit (bad ? 1 : 0)
    }
  ' "$1"
}

_tf_rows() { grep -c . "$1" 2>/dev/null || echo 0; }

# _tf_stamp -- remember that the store, as it is right now, validated. The gate
# then costs a cksum instead of a parse until something changes the files.
_tf_stamp_value() { cat "$CSV" "$STATE" 2>/dev/null | cksum; }
_tf_stamp() { mkdir -p "$CACHE"; _tf_stamp_value > "$CACHE/.integrity" 2>/dev/null || :; }

# _tf_backup <store-file> -- keep a copy before it is replaced.
#
# Two kinds. `<name>.last.csv` is always the most recent version the engine
# wrote, so damage done afterwards by anything else loses nothing. Timestamped
# copies are taken at most every BACKUP_EVERY_MIN and the newest BACKUP_KEEP kept,
# so a bad-but-valid change (a wrong import) can still be walked back.
_tf_backup() {
  _b_f="$1"; [ -f "$_b_f" ] || return 0
  mkdir -p "$BACKUPS"
  _b_n="$(basename "$_b_f" .csv)"
  # -mmin is in GNU, BSD and busybox find alike; `date -r` is not portable.
  _b_recent="$(find "$BACKUPS" -name "$_b_n.[0-9]*.csv" -mmin -"$BACKUP_EVERY_MIN" 2>/dev/null | head -1)"
  if [ -z "$_b_recent" ] && _tf_validate "$_b_f" 2>/dev/null; then
    cp "$_b_f" "$BACKUPS/$_b_n.$(date +%Y%m%d-%H%M%S).csv" 2>/dev/null
    ls -1t "$BACKUPS/$_b_n".[0-9]*.csv 2>/dev/null | tail -n +$((BACKUP_KEEP + 1)) |
      while IFS= read -r _b_old; do rm -f "$_b_old"; done
  fi
  return 0
}

# _tf_commit <tmp> <dest> [--allow-shrink] -- the only way a store file is
# replaced. Refuses a malformed file, and refuses to lose rows unless the caller
# says that is the point (prune). On refusal the tmp file is removed, dest is
# untouched, and the return is 1.
_tf_commit() {
  _c_tmp="$1"; _c_dest="$2"; _c_opt="${3:-}"
  if ! _tf_validate "$_c_tmp" 2>"$_c_tmp.why"; then
    echo "tf: refusing to write $_c_dest -- the new version does not parse:" >&2
    cat "$_c_tmp.why" >&2
    rm -f "$_c_tmp" "$_c_tmp.why"
    return 1
  fi
  rm -f "$_c_tmp.why"
  if [ -f "$_c_dest" ] && [ "$_c_opt" != "--allow-shrink" ]; then
    _c_old="$(_tf_rows "$_c_dest")"; _c_new="$(_tf_rows "$_c_tmp")"
    if [ "$_c_new" -lt "$_c_old" ]; then
      echo "tf: refusing to write $_c_dest -- it would drop from $((_c_old - 1)) to $((_c_new - 1)) rows" >&2
      rm -f "$_c_tmp"
      return 1
    fi
  fi
  _tf_backup "$_c_dest"
  mv "$_c_tmp" "$_c_dest" || return 1
  mkdir -p "$BACKUPS"
  cp "$_c_dest" "$BACKUPS/$(basename "$_c_dest" .csv).last.csv" 2>/dev/null
  _tf_stamp
  return 0
}

# _tf_gate -- stop before reading a damaged store. Exit 3: the environment is
# broken, not the app.
_tf_gate() {
  [ -f "$CSV" ] || return 0
  head -1 "$CSV" | grep -q '^id,feature,role' && return 0   # old schema; migrate owns it
  if [ -f "$CACHE/.integrity" ] && [ "$(_tf_stamp_value)" = "$(cat "$CACHE/.integrity" 2>/dev/null)" ]; then
    return 0
  fi
  mkdir -p "$CACHE"
  for _g_f in "$CSV" "$STATE"; do
    [ -f "$_g_f" ] || continue
    if ! _tf_validate "$_g_f" 2>"$CACHE/.gate.$$"; then
      cat "$CACHE/.gate.$$" >&2; rm -f "$CACHE/.gate.$$"
      die3 "$_g_f is damaged, so nothing was read or written.
    Something other than tf.sh rewrote it. Run: tf.sh restore"
    fi
  done
  rm -f "$CACHE/.gate.$$"
  _tf_stamp
}

# check -- is the store readable? Reports every problem, and duplicate ids.
cmd_check() {
  need_csv
  rc=0
  for f in "$CSV" "$STATE"; do
    [ -f "$f" ] || continue
    if _tf_validate "$f"; then
      echo "check: $f ok ($(( $(_tf_rows "$f") - 1 )) rows)"
    else
      echo "check: $f is DAMAGED -- run: tf.sh restore" >&2; rc=1
    fi
    dups="$(awk "$AWKLIB"'NR > 1 { csvsplit($0, F); if (F[1] != "" && S[F[1]]++ == 1) printf "%s ", F[1] }' "$f" 2>/dev/null)"
    [ -z "$dups" ] || echo "check: $f has duplicate ids: $dups" >&2
  done
  [ "$rc" = 0 ] && _tf_stamp
  return $rc
}

# restore [--from backup|xlsx] -- put back the last store that parses.
#
# Each damaged file is replaced by the newest backup of it that validates:
# `.last` first (what the engine last wrote), then the timestamped copies. With
# no usable backup of testcases.csv, the workbook is imported instead. The
# damaged file is kept beside the original as *.damaged.<time>.
cmd_restore() {
  from=any
  case "${1:-}" in
    --from) from="${2:-}"; case "$from" in backup|xlsx) ;; *) die "restore: --from backup or --from xlsx" ;; esac ;;
    "") ;;
    *) die "restore: unknown option $1" ;;
  esac
  ts="$(date +%Y%m%d-%H%M%S)"
  for f in "$CSV" "$STATE"; do
    [ -f "$f" ] || continue
    if [ "$from" = any ] && _tf_validate "$f" 2>/dev/null; then
      echo "restore: $f is fine, left alone"; continue
    fi
    [ "$from" = xlsx ] && [ "$f" = "$STATE" ] && continue
    n="$(basename "$f" .csv)"; before="$(( $(_tf_rows "$f") - 1 ))"; pick=""
    if [ "$from" != xlsx ]; then
      for b in "$BACKUPS/$n.last.csv" $(ls -1t "$BACKUPS/$n".[0-9]*.csv 2>/dev/null); do
        [ -f "$b" ] || continue
        cmp -s "$b" "$f" && continue
        _tf_validate "$b" 2>/dev/null && { pick="$b"; break; }
      done
    fi
    if [ -n "$pick" ]; then
      cp "$f" "$f.damaged.$ts"; cp "$pick" "$f"
      echo "restore: $f <- $pick ($before -> $(( $(_tf_rows "$f") - 1 )) rows; damaged copy at $f.damaged.$ts)"
    elif [ "$f" = "$CSV" ] && [ "$from" != backup ] && [ -f "$XLSX" ]; then
      cp "$f" "$f.damaged.$ts"; printf '%s\n' "$HEADER" > "$f"; _tf_stamp
      cmd_xlsx --import >&2 || die3 "restore: importing $XLSX failed; the damaged file is at $f.damaged.$ts"
      echo "restore: $f <- $XLSX ($before -> $(( $(_tf_rows "$f") - 1 )) rows; damaged copy at $f.damaged.$ts)"
    else
      die3 "restore: no usable backup of $f, and nothing else to rebuild it from. The damaged file is untouched."
    fi
  done
  _tf_gate
}
