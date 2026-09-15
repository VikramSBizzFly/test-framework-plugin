---
name: test-execution
description: Run browser cases - native specs and recipe replay through the Playwright MCP - after tf.sh run-api has cleared the free cases. Use during /test-run stage 3/4, or whenever a `page` case needs to run, a locator cache needs refreshing, or a browser failure needs triage.
---

# Execution

> `tf.sh` = `"$CLAUDE_PLUGIN_ROOT/scripts/tf.sh"` (not on PATH).

Everything free already ran before this skill loads. Stage 3 (and 4) of
`/test-run`'s cheapest-engine-first, browser-last order:

1. `tf.sh run-api` — `type=api`, curl, zero tokens (not this skill).
2. **native runner** — any case with a `spec_file`: the project's own
   `spec_dir`/command, no MCP. Parse into `run-api`'s shape
   (`tf.sh junit <xml>` if there's no adapter).
3. **recipe replay** — remaining `type=page` rows: delegate to the
   `test-runner` agent, one route group at a time, over a real browser —
   the only tier that looks at rendered content, which is why `page` exists.
4. **triage** — failures only. A passing case is never re-examined.

## Two gates before a browser opens

`tf.sh preflight`, if stage 1 didn't already — refuses a non-local
`base_url` unless `framework.json` sets `allow_remote`. `tf.sh cost --check`
— exit 1 means the projection exceeds `max_tokens_per_run`: stop, report it,
don't start a capped run. Narrow (`--tag smoke`, `--changed`, `--module`)
or ask them to raise the cap. Stages 1-2 are free and run regardless.

**Sessions expire mid-run.** Don't read a wave of same-role failures as the
app breaking — hand the role to `login-broker` and continue. Blame the app only
once a fresh session still fails. Sessions, the two auth artifacts and the
credential rules are owned by the **test-auth** skill.

## Routing

`tf.sh select --type page --cols id,role,route,status,spec_file`.

| `status` | `spec_file` | action |
| --- | --- | --- |
| `Not Run` | empty | not compiled — send to `test-compilation` first |
| `Not Run` | set | compiled, never run — replay it (or native runner) |
| `Pass` | set | native runner |
| `Pass` | empty | replay it |
| `Fail` / `Blocked` | any | replay again; still counts toward the circuit breaker |
| `skipped` | any | destructive, or opted out — skip unless `--allow-destructive` |

`--headed` shows the browser instead of headless.

## Delegating, folding, triage

Group by `route`, then `who`; one `test-runner` call per group. **Never run
two concurrently** — one browser is shared mutable state. `test-runner`
returns only `id,verdict,duration_ms,failure_class,evidence_path`; reshape
to `id,type,role,route,expected,actual,verdict,ms` and append to the
`run-<ts>.csv` stage 1 started, so `tf.sh summary` covers the whole run.
Fold with `tf.sh setmany`: PASS → `status=Pass`; a differing verdict still
lands `Pass` but bumps `flake_count`; FAIL → `status=Fail`; ERROR → `status=Blocked`.
Write what the page actually showed into `actual`, in one sentence.

Triage **failures only**, from `evidence_path` alone. Sequencing, the locator
cache, ambient-failure rules and the circuit breaker: `references/protocol.md`.
