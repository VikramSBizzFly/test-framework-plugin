---
description: Find pages, write the tests, and run them in a browser
---

> `tf.sh` = `"$CLAUDE_PLUGIN_ROOT/scripts/tf.sh"` (not on PATH).

Run the tests. Arguments: `$ARGUMENTS`

Flags: `--changed` `--all` `--feature <area>` `--only-failing` `--headed`
`--fresh` `--allow-destructive` `--crawl` `--a11y` `--security` `--responsive`.

**Bare `/test-run` means `--changed`**, falling back to high-priority cases when
nothing has changed. A full browser run takes minutes, so the whole suite is
always an explicit `--all`.

## 1. Check the app is up

`tf.sh preflight`. If it is down, stop and say so. A dead app should cost one
request, not a suite of failures.

Then confirm each role still has a session — both `tests/.auth/<role>.cookies`
and `tests/.auth/<role>.json`. Sessions expire; if one has, hand that role to
the `login-broker` agent now rather than discovering it forty cases later. A
role whose storage state is missing makes every browser case "pass".

## 2. Write or refresh the tests

**`tf.sh xlsx --import` first**, always — the workbook is the store, and
someone may have edited a status, a note or added a case since the last run.
Hand edits win; do this before anything reads the suite.

Then `tf.sh cache-check <src>`. **Exit 0 means skip the rest of this step** —
the source has not changed, the existing cases are current, and regeneration is
free. Only continue on exit 1, or with `--fresh`.

Otherwise load the **test-discovery** skill and delegate — none of this belongs
in the main thread:

```sh
tf.sh routes <src> > tests/.cache/routes.txt
```

1. `test-explorer` agents, in parallel, one per slice of the route list → the
   feature grouping in `tests/.cache/featuremap.txt` and the privileged routes
   in `tests/.cache/privileged.txt`.
2. `route-crawler`, **only on `--crawl`** or when static extraction clearly
   under-reports (a client-rendered nav). One at a time; it shares the browser.
3. The free permission sweep:

```sh
tf.sh rbac tests/.cache/routes.txt tests/.cache/privileged.txt > /tmp/new.csv
tf.sh merge /tmp/new.csv
```

4. `flow-mapper` agents, one per feature, for the flows behind those routes →
   `tests/.cache/flows.txt`. Routes say where the app goes; flows say what it is
   for, and they are what the end-to-end cases are written from.
5. `case-author` agents, one per feature in the featuremap, for the cases the
   sweep does not cover — from the page models **and** the flows.
6. `api-case-author`, once, for `type=api` cases from the project's own
   contract — those run on curl for zero tokens.
7. `security-prober` case generation, **on `--security`**, for the boundaries
   the role-by-route matrix cannot express.

```sh
tf.sh prune --apply
```

`merge` never overwrites a `status` or a `notes` the user wrote, so this is
always safe to re-run.

## 3. Check the cost before spending it

`tf.sh cost --check`. Exit 1 means the projection exceeds `max_tokens_per_run`
in `tests/framework.json` — stop, show the projection, and suggest narrowing
(`--changed`, `--feature`) rather than starting a run they capped.

## 3.5 Model each route once, then compile on paper

This is where the framework's cost model lives. **Do it before any browser case
runs.**

1. For every `page` case whose route has no `tests/.cache/pages/<route>.txt` —
   or whose model predates the last source hash — call the `page-modeler` agent
   for that route. One route per call, one snapshot each, never two at once.
2. Then call the `test-compiler` agent per route. It reads the page model and
   compiles **every** case on that route into `tests/.cache/recipes/<id>.rcp`
   without opening a browser, and writes `spec_file` back.

A route is understood once; every later run replays its recipes. Skipping this
step leaves `test-runner` with nothing to replay.

## 4. Run them, cheapest first

1. **`tf.sh run-api`** — `type=api` cases, over curl. Free. Always run these
   first; they are fast and a broken build shows up before a browser opens.
2. **Promoted specs** — any case with a `spec_file`, run by the project's own
   test command. Also free.
3. **Browser** — everything else. Load the **test-execution** skill and hand
   route groups to the `test-runner` agent, one group at a time — never two
   browser agents at once. `--headed` shows the browser.
   On `--a11y`, one `a11y-auditor` call per route in the same serial queue; on
   `--security`, one `security-prober` call per feature; on `--responsive`, one
   `responsive-auditor` call per route, which checks 390/768/1280.
4. **Failures only** get further attention: the `test-triager` agent, one
   failing case per call, per **test-triage**. A `tags=visual` diff goes to
   `visual-reviewer` instead. A passing case is never re-examined.
5. **Promote, at Tier >= 1.** Hand the ids that just passed in the browser to
   the `spec-writer` agent. It writes native specs in the project's own
   language, and those re-run for zero tokens from then on. At Tier 0 skip
   this — there is no runner to write into.

## 4.6 Write the results into the workbook

`tf.sh xlsx --status` — every case that ran gets its verdict, timestamp and
evidence path written into `tests/testcases.xlsx`, and each flow's status is
rolled up from the cases covering it. A verdict that did not change rewrites
nothing.

## 5. Print the panel

`tf.sh summary` prints at the end of the run. **Print it verbatim and add
nothing** — no restating counts, no re-listing failures, no congratulating.

Say something only if the panel cannot: the app would not start, a login
failed, or you deliberately ran a narrow selection.
