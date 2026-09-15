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
# testcases.csv is the QA team's layout: ten columns, the words a tester uses,
# and nothing the engine needs to run. A run rewrites two of its cells --
# `Status` and `Actual Result` -- and only when a verdict actually changed, so
# the file does not churn in git and hand edits survive.
#
# .cache/state.csv is the bookkeeping the runner needs and nobody wants to read.
# Keyed by id, regenerable, never hand-edited. `role` lives here rather than in
# the visible sheet: Preconditions says "Logged in as admin" for a person, and
# state says `admin` for the runner.
HEADER='Test Case ID,Module,Test Scenario,Test Description,Preconditions,Test Case Steps,Test Data,Expected Result,Actual Result,Status'
STATE_HEADER='id,type,route,tags,source_files,spec_file,last_run,last_result,pass_streak,flake_count,viewport,method,body,headers,expect_code,repeat,role'

# Columns that live in testcases.csv. Everything else is routed to state.csv.
HUMAN_COLS='Test Case ID Module Test Scenario Test Description Preconditions Test Case Steps Test Data Expected Result Actual Result Status'

# tests/.cache/bugs.csv -- the bug store behind tests/bug-report.xlsx. The
# visible 17 columns a bug sheet carries, plus `case_id`, which ties a bug to
# the case that raised it so a second failure updates instead of duplicating.
BUGS="$CACHE/bugs.csv"
BUG_XLSX="$TESTS_DIR/bug-report.xlsx"
BUG_HEADER='Bug No,Module,Bug Description,Steps to Reproduce,Expected Result,Actual Result,Test data,Status(QA),QA Comments,Severity,Priority,Reporter,Environment,Access Link,Bug Link,found date,Dev Comment,case_id'


# ------------------------------------------------------------------- modules
# The engine is split by concern under scripts/lib/. Each module only defines
# functions, so the load order does not matter; this file owns the paths, the
# schema, `usage` and the dispatcher. Look next to this script first -- that is
# always the matching version -- and fall back to the plugin root.
TF_LIB="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)/lib"
[ -f "$TF_LIB/core.sh" ] || TF_LIB="${CLAUDE_PLUGIN_ROOT:-}/scripts/lib"
for _m in core progress store integrity discovery generate auth api report migrate bugs xlsx; do
  [ -f "$TF_LIB/$_m.sh" ] || { echo "tf: missing module $TF_LIB/$_m.sh -- reinstall the plugin" >&2; exit 3; }
  # shellcheck disable=SC1090
  . "$TF_LIB/$_m.sh"
done
unset _m

usage() {
  cat <<'EOF'
tf.sh - deterministic engine for the Claude test framework

cases      init-csv | select | set | setmany | merge | next-id | stats | prune | migrate
bugs       bug from | bug set | bug list
store      check | restore
excel      xlsx [--import|--status]
discovery  routes | forms | schemas | hash | cache-check | impacted | cover
generate   rbac
execute    login | storage-state | preflight | run-api
report     summary | watch | cost | diff | junit | render | latest
meta       version | help

  select --status "Not Run" --role nobody --module admin \
         --cols id,steps,expected,route --limit 20 --count --format plain
  set AUTH-002 status=Fail "actual=HTTP 200, payroll rendered"
  merge /tmp/new-cases.tsv        additive; never overwrites status or notes
  merge --check /tmp/new.tsv      validate only; a malformed row rejects the file
  check                           is the store readable? (line numbers if not)
  restore [--from backup|xlsx]    put back the last store that parses
  migrate                         convert an old 20-column suite
  routes src/ > tests/.cache/routes.txt
  rbac tests/.cache/routes.txt > /tmp/rbac.csv
  run-api [--allow-destructive]
  storage-state admin            cookie jar -> Playwright storage state
  bug from AUTH-002 "Bug Description=..." Severity=Critical
  bug set BUG-003 "Bug Link=https://github.com/o/r/issues/12"
  bug list [--status Open]
  xlsx                           rebuild both workbooks
  xlsx --import                  pull hand edits back out of the sheets
  xlsx --status                  write verdicts back after a run

Ten visible columns: Test Case ID, Module, Test Scenario, Test Description,
Preconditions, Test Case Steps, Test Data, Expected Result, Actual Result,
Status. Status is one of: Not Run, Pass, Fail, Blocked, Flaky, Skipped.
Bookkeeping the runner needs (route, role, tags, ...) lives in
tests/.cache/state.csv; `select` joins the two for you.

Never `cat` the store. Query it.
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
  bug)       cmd_bug "$@" ;;
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
