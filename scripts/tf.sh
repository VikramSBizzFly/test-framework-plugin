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


# ------------------------------------------------------------------- modules
# The engine is split by concern under scripts/lib/. Each module only defines
# functions, so the load order does not matter; this file owns the paths, the
# schema, `usage` and the dispatcher. Look next to this script first -- that is
# always the matching version -- and fall back to the plugin root.
TF_LIB="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)/lib"
[ -f "$TF_LIB/core.sh" ] || TF_LIB="${CLAUDE_PLUGIN_ROOT:-}/scripts/lib"
for _m in core progress store integrity discovery generate auth api report migrate xlsx; do
  [ -f "$TF_LIB/$_m.sh" ] || { echo "tf: missing module $TF_LIB/$_m.sh -- reinstall the plugin" >&2; exit 3; }
  # shellcheck disable=SC1090
  . "$TF_LIB/$_m.sh"
done
unset _m

usage() {
  cat <<'EOF'
tf.sh - deterministic engine for the Claude test framework

CSV        init-csv | select | set | setmany | merge | next-id | stats | prune | migrate
store      check | restore
excel      xlsx [--import|--status]
discovery  routes | forms | schemas | hash | cache-check | impacted | cover
generate   rbac
execute    login | storage-state | preflight | run-api
report     summary | watch | cost | diff | junit | render | latest
meta       version | help

  select --status new --priority high --who nobody --area admin \
         --cols id,todo,route --limit 20 --count --format plain
  set AUTH-002 status=failing notes="shows the page to everyone"
  merge /tmp/new-cases.tsv        additive; never overwrites status or notes
  merge --check /tmp/new.tsv      validate only; a malformed row rejects the file
  check                           is the store readable? (line numbers if not)
  restore [--from backup|xlsx]    put back the last store that parses
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

[ $# -gt 0 ] || { usage; exit 0; }
sub="$1"; shift

# Housekeeping first -- except for the two subcommands that answer without
# touching a suite at all.
case "$sub" in
  help|-h|--help|version|-v|--version) ;;
  *) tf_auto_migrate ;;
esac

# Then refuse to read or write a store that no longer parses. `check` and
# `restore` are how you get out of that state, so they are not gated; neither
# are the subcommands that never open the store.
case "$sub" in
  help|-h|--help|version|-v|--version|check|restore|init-csv|migrate) ;;
  routes|forms|schemas|hash|cache-check|login|storage-state|preflight) ;;
  junit|diff|render|summary|watch|latest|rbac) ;;
  *) _tf_gate ;;
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
  check)     cmd_check "$@" ;;
  restore)   cmd_restore "$@" ;;
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
