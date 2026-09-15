# shellcheck shell=sh
# lib/xlsx.sh -- the Excel workbook bridge
#
# Sourced by scripts/tf.sh; defines functions only. See tf.sh for the paths
# and schema variables these rely on.

# xlsx [--import|--status] -- the Excel side.
#
# Two workbooks, both maintained here, and scripts/tf-xlsx.py is the only thing
# that touches either file:
#
#   tests/testcases.xlsx    Flows, Test Cases (the QA team's ten columns),
#                           Results
#   tests/bug-report.xlsx   Bugs, in the team's bug-sheet columns
#
#   (no flag)  rebuild both from the stores, flows.txt and the last run
#   --import   pull hand edits back from both: every case column; for bugs,
#              only the columns a person owns
#   --status   refresh both after a run
#
# Writing a .xlsx needs an interpreter, so a machine without one gets a line on
# stderr and exit 0 -- never a failed run. The CSVs are still correct there.
#
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
    echo "xlsx: no python on PATH -- the workbooks are not maintained here; $CSV is current" >&2
    return 0
  fi

  need_csv
  mkdir -p "$CACHE"
  # The ten visible columns plus the run details the Results and Flows sheets
  # need. The header comes out as the visible labels, which tf-xlsx.py reads.
  joined="$CACHE/.xlsx-cases.$$"
  cmd_select --cols id,module,scenario,description,preconditions,steps,data,expected,actual,status,route,tags,viewport,role,last_run,last_result \
             --format csv > "$joined" 2>/dev/null || : > "$joined"
  flows="$CACHE/flows.txt"
  latest="$(cmd_latest 1 2>/dev/null | head -1)"

  rc=0
  case "$mode" in
    export|status)
      "$py" "$script" "$( [ "$mode" = status ] && echo status || echo export )" \
        --xlsx "$XLSX" --cases "$joined" --flows "$flows" --results "$latest" || rc=$?
      _tf_xlsx_bugs_export || rc=$?
      ;;
    import)
      if [ -f "$XLSX" ]; then
        newf="$CACHE/.xlsx-new.$$"; humanf="$CACHE/.xlsx-human.$$"
        if "$py" "$script" import --xlsx "$XLSX" --cases "$joined" \
             --out-human "$humanf" --out-new "$newf"; then
          # New rows first, so state.csv gains their bookkeeping, then the
          # visible columns wholesale -- the sheet is the source of truth for
          # those.
          if [ "$(wc -l < "$newf" 2>/dev/null || echo 1)" -gt 1 ]; then
            cmd_merge "$newf" >&2 || rc=$?
          fi
          _tf_commit "$humanf" "$CSV" || rc=$?
        else
          rc=$?
        fi
        rm -f "$newf" "$humanf"
      else
        echo "xlsx: no $XLSX yet, nothing to import" >&2
      fi
      _tf_xlsx_bugs_import || rc=$?
      ;;
  esac
  rm -f "$joined"
  return $rc
}

# The bug report. Nothing to do until the first bug exists.
_tf_xlsx_bugs_export() {
  [ -f "$BUGS" ] || return 0
  "$py" "$script" bugs-export --xlsx "$BUG_XLSX" --bugs "$BUGS"
}

_tf_xlsx_bugs_import() {
  [ -f "$BUG_XLSX" ] && [ -f "$BUGS" ] || return 0
  _bi_out="$CACHE/.xlsx-bugs.$$"
  if "$py" "$script" bugs-import --xlsx "$BUG_XLSX" --bugs "$BUGS" --out "$_bi_out"; then
    _tf_commit "$_bi_out" "$BUGS" || { rm -f "$_bi_out"; return 1; }
  else
    rm -f "$_bi_out"; return 1
  fi
}
