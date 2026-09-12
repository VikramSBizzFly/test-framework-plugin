---
name: test-flows
description: Map what a web app actually does end to end - the user journeys and business flows behind the routes, with the code path, the data each one writes, and the ways each can fail. Use when asked to map or list the flows or user journeys of an app, before authoring test cases for a feature, or when a flow's coverage or status is in question.
---

# Flows

> `tf.sh` = `"$CLAUDE_PLUGIN_ROOT/scripts/tf.sh"` (not on PATH).

A route list tells you where the app can go. A flow tells you what it is *for*.
Test cases written per route check pages; test cases written per flow check that
the software does its job — and a bug that only appears at step four of five is
invisible to any per-page test.

Delegate the reading to the `flow-mapper` agent, **one call per feature area**
from `tests/.cache/featuremap.txt`, so a large codebase fans out instead of
drowning one context.

## What counts as a flow

What a user or the system **accomplishes**: "log in", "create an invoice",
"reset a password", "run payroll", "the nightly export". Not a route, not a
page, not a function. `/invoices`, `/invoices/new` and `POST /invoices` are one
flow, not three.

Each flow records: who can start it, what triggers it, the ordered steps, the
code path down to the data layer, what it writes, and how it can fail.

## The rule that keeps it honest

**Every branch you write down must exist in the code, cited `path:line`.**
A plausible-sounding failure mode that the app cannot actually produce turns
into a test case that can never pass, and nobody can tell whether that is a bug
in the app or a lie in the suite. When you cannot tell, say so in `UNCLEAR` —
an admitted gap is worth more than a confident guess.

Trace to the data layer or the outbound call, then stop. Nobody needs the
framework's router explained.

## Where flows live

The `Flows` sheet of `tests/testcases.xlsx` — the same workbook as the cases.
The agent writes `tests/.cache/flows.txt` (tab-separated, line-oriented, so awk
can read it) and `tf.sh xlsx` renders it into the sheet. Format and worked
examples: `references/flow-format.md`.

After a run, each flow's status is rolled up from the cases covering it:
`passing` only if they all passed, `failing` if any did, `partial` when they
disagree, and **`not covered` when no case references it at all**. That last
value is the useful one — it is the list of things the app does that nobody
tests.

## Flows and cases

`case-author` reads the flows and writes the end-to-end case for each one, then
writes the case ids back into the flow's `cases` field. A flow marked `[priv]`
crosses a privilege boundary and earns `tags=security`; a flow whose `writes`
column is non-empty earns a `tags=destructive` case, left `skipped`.
