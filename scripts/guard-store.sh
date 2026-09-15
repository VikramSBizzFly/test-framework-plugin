#!/bin/sh
# guard-store.sh - PreToolUse hook: nothing but tf.sh rewrites the case or bug store.
#
# testcases.csv, .cache/state.csv and .cache/bugs.csv are read a line at a time by awk. A file
# pretty-printed into aligned columns, or re-saved by a tool that quotes
# differently, looks fine to a person and is garbage to the engine -- and it has
# happened. tf.sh validates and backs up every write; a Write, an Edit or a
# shell redirect does neither. So those are refused here, with the command that
# does the job safely.
#
# Reads the hook's JSON on stdin. POSIX sh + grep only: no jq, no runtime.
# Exit 0 allows the call; exit 2 blocks it and shows stderr to the model.

input="$(cat)"
# The file name must start a path segment: new-testcases.csv is someone's
# scratch file, and only the state.csv under .cache/ is ours.
name='(testcases\.csv|\.cache[/\\]+(state|bugs)\.csv)'
store="(^|[^A-Za-z0-9_.-])$name"
target="([^[:space:]|;&]*[/\\\\])?$name"   # an optional directory, then the name

block() {
  echo "Blocked: $1 would rewrite the test case or bug store directly." >&2
  echo "The store is read line by line and one malformed row shifts every column." >&2
  echo "Use tf.sh instead: set <id> col=value, merge <file.tsv>, prune --apply," >&2
  echo "bug from <case-id> ..., bug set <BUG-NNN> col=value," >&2
  echo "or xlsx --import for edits made in the workbook. Damaged already? tf.sh restore" >&2
  exit 2
}

tool="$(printf '%s' "$input" | grep -oE '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]*)"$/\1/')"

case "$tool" in
  Write|Edit|MultiEdit|NotebookEdit)
    # JSON escapes Windows backslashes, so accept / \ or \\ before the name.
    path="$(printf '%s' "$input" | grep -oE '"(file_path|notebook_path)"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1)"
    if printf '%s' "$path" | grep -qE '(^|[/\\])testcases\.csv"$|\.cache[/\\]+(state|bugs)\.csv"$'; then
      block "$tool"
    fi
    ;;
  Bash|PowerShell)
    cmd="$(printf '%s' "$input" | grep -oE '"command"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' | head -1)"
    # A store file as the target of a redirect, tee, in-place edit, move, copy
    # or an open-for-write. Reading it (cat, grep, cp it elsewhere) is allowed.
    end='([^A-Za-z0-9_.-]|$)'
    if printf '%s' "$cmd" | grep -qE ">[[:space:]]*$target$end" ||
       printf '%s' "$cmd" | grep -qE "(tee|Set-Content|Out-File|Add-Content)([[:space:]]+-[A-Za-z]+)*[[:space:]]+$target$end" ||
       printf '%s' "$cmd" | grep -qE "sed[[:space:]]+(-[A-Za-z]*[[:space:]]+)*-i[^|;&]*$store$end" ||
       printf '%s' "$cmd" | grep -qE "(^|[[:space:];&|\"])(mv|cp|Move-Item|Copy-Item)[[:space:]]+(-[A-Za-z]+[[:space:]]+)*[^[:space:]|;&]+[[:space:]]+$target$end" ||
       printf '%s' "$cmd" | grep -qE "$store[^|;&,]{0,8},[[:space:]]*[\\\\]*[\"'][wa]"; then
      block "this command"
    fi
    ;;
esac
exit 0
