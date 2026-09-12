#!/bin/sh
# qa-hint.sh -- UserPromptSubmit hook for the test-framework plugin.
#
# Reads the hook payload on stdin, and when the prompt looks like a QA request
# prints one line of additionalContext pointing at the `qa` skill. Prints
# nothing otherwise.
#
# Three rules, because this runs on every prompt the user types:
#   1. ALWAYS exit 0. Exit 2 would erase the user's prompt; any other non-zero
#      shows an error in their transcript. A hook that fails loudly on every
#      turn is worse than no hook at all.
#   2. No dependency beyond POSIX sh + awk + grep -- the same floor tf.sh
#      assumes. Never jq, never node, never python.
#   3. Say nothing when there is nothing to say. Silence is the common case.
set -u

payload="$(cat 2>/dev/null)" || exit 0
[ -n "$payload" ] || exit 0

# The user already chose a command; don't editorialise.
case "$payload" in
  *'"user_input_kind":"slash_command"'*|*'"user_input_kind": "slash_command"'*) exit 0 ;;
esac

# Pull "user_input" out of the JSON without a JSON parser: find the key, skip
# the colon and opening quote, then read to the first unescaped quote.
prompt="$(printf '%s' "$payload" | awk '
  { line = line $0 }
  END {
    key = "\"user_input\""
    p = index(line, key)
    if (p == 0) exit
    rest = substr(line, p + length(key))
    # Require a real  : "  -- without it this is not a JSON string value, and
    # we would match keywords in the raw text of a malformed payload.
    if (sub(/^[ \t]*:[ \t]*"/, "", rest) != 1) exit
    n = length(rest)
    for (i = 1; i <= n; i++) {
      c = substr(rest, i, 1)
      if (c == "\\") { i++; continue }
      if (c == "\"") break
      out = out c
    }
    print tolower(out)
  }' 2>/dev/null)" || exit 0
[ -n "$prompt" ] || exit 0

# Two tiers. Strong terms name something this plugin actually does, so they
# match on their own. Weak pairs need a thing AND an intent, which is what
# separates "does checkout actually work?" from "add a login page".
kw='(^|[^a-z])('
kw=$kw'test|tests|testing|tested|testcase|testcases|test case|test cases|test suite|qa|smoke test|e2e|end-to-end|regression|regressions|flaky|'
kw=$kw'bug|bugs|buggy|broken|defect|not working|doesnt work|does not work|failing|fails|'
kw=$kw'flow|flows|user flow|user journey|journey|journeys|happy path|map the app|walk through the app|'
kw=$kw'permission|permissions|unauthorised|unauthorized|access control|rbac|privilege|idor|leak|leaking|'
kw=$kw'responsive|breakpoint|breakpoints|mobile view|small screen|tablet|layout break|overflowing|'
kw=$kw'accessibility|a11y|screen reader|wcag|aria|'
kw=$kw'visual regression|baseline|baselines|screenshot diff|pixel|'
kw=$kw'endpoint|endpoints|curl|api test|'
kw=$kw'playwright|selenium|cypress|browser test|headless|'
kw=$kw'coverage|test report|bug report|untested|'
kw=$kw'testcases.xlsx|test case file|test cases file|'
kw=$kw'ci pipeline|github actions'
kw=$kw')([^a-z]|$)'

# A permission or behaviour question often arrives with no QA vocabulary at all
# -- "can a normal user open the payroll page?" -- so match a thing plus an
# intent as a second net.
role='(normal user|regular user|logged.out|logged out|anonymous|not logged in|another user|other users|someone else|admin.only|non.admin)'
thing='(app|site|website|page|pages|route|routes|screen|form|login|signup|checkout|dashboard|ui|layout|endpoint)'
intent='(check|verify|validate|find|look for|anything wrong|is it working|does it work|make sure|try it)'
reach='(see|view|open|access|read|reach|land on)'

# "flow" is also a code-reading word. A flow chart of a function is not a user
# flow, so these bow out unless the prompt is plainly about the app itself.
nope='(flow ?chart|flow diagram|control flow|data flow|flow of (this|the) (function|method|code))'
if printf '%s' "$prompt" | grep -Eq "$nope" 2>/dev/null; then
  printf '%s' "$prompt" | grep -Eq '(app|site|website|user journey)' 2>/dev/null || exit 0
fi

match=0
printf '%s' "$prompt" | grep -Eq "$kw" 2>/dev/null && match=1
if [ "$match" -eq 0 ]; then
  if printf '%s' "$prompt" | grep -Eq "$role" 2>/dev/null; then
    printf '%s' "$prompt" | grep -Eq "$reach" 2>/dev/null && match=1
  fi
fi
if [ "$match" -eq 0 ]; then
  if printf '%s' "$prompt" | grep -Eq "$thing" 2>/dev/null; then
    printf '%s' "$prompt" | grep -Eq "$intent" 2>/dev/null && match=1
  fi
fi
[ "$match" -eq 1 ] || exit 0

cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"The test-framework plugin is installed in this session. If this request is about a running web app -- testing it, finding bugs, mapping its flows or user journeys, checking permissions or access control, checking API endpoints, responsive or mobile layout, accessibility, or the test cases workbook -- load its `qa` skill first: it routes to /test-setup, /test-run or /test-report, runs the free checks immediately, and asks before anything slow or destructive. If the request is a unit test for a single function, a question about the project's own test library, or not about a web app, ignore this note entirely."}}
JSON
exit 0
