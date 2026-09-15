---
name: test-compilation
description: Compile a route's page model plus its testcases.csv rows into recipe files, on paper, with no browser. Use during /test-run before browser execution, or whenever a `page` case has status new but no spec_file, or a page model changed and its recipes need recompiling.
---

# Compilation

> `tf.sh` = `"$CLAUDE_PLUGIN_ROOT/scripts/tf.sh"` (not on PATH).

Delegate this to the `test-compiler` agent, one call per route — page models
and case text are exactly what the main thread should never hold.

The browser is expensive; text transformation is free. A **page model** at
`tests/.cache/pages/<route>.txt` (written once, by `page-modeler`) is read
here to compile **every** case on that route — this step never opens a
browser and never calls the Playwright MCP.

For each `page` row whose route has a page model: read the model, read the
case's **Test Case Steps**, **Test Data** and **Expected Result**, emit `tests/.cache/recipes/<id>.rcp`.
See `references/grammar.md` for the full verb list and worked examples,
including how to judge a rendered permission failure.

## The two rules that dominate cost

**Direct navigation, never click-paths.** Seed the role's storage state
(`tests/.auth/<role>.json`) and `nav` straight to the case's target route.
Do not recipe a login flow to get there — that is Compilation using an
element that exists only to route around this rule. This alone more than
halves steps per case.

**Assert once, at the end.** Action steps (`fill`, `click`, `select`, `check`)
never produce something a model reads later. Only the trailing `expect *`
lines are checked. A recipe with an `expect` in the middle is a sign the case
should have been split, or should have been `api` instead.

**Judging a permission failure needs the rendered page, not a status code.**
(The **test-security** skill owns this rule and why the framework is built
around it.)
A refusal can be a redirect, a banner, or a page that returns 200 with
"Access denied" in the body — `expect any-of` and `expect not-text` exist for
exactly this. See `references/grammar.md`.

## Credentials

Reference role credentials as `$role.username` / `$role.password`. **Never**
write a literal username or password into a recipe file — recipes land in
`tests/.cache/`, which is not gitignored the way `credentials.json` is.

## After compiling

Write `spec_file=tests/.cache/recipes/<id>.rcp` back with `tf.sh setmany`.
Leave `status` alone — it stays `Not Run`; compiling isn't running, so only a
real pass under `test-execution` earns `status=Pass`. Presence of
`spec_file` on a `Not Run` row is what tells execution "compiled, ready to
replay" instead of "needs compiling first." A route with no page model yet
compiles nothing; hand that route to `page-modeler` first.
