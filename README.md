# test-framework

## Install

```
/plugin marketplace add vikrambizzfly/test-framework-plugin
/plugin install test-framework@test-framework
```

Then restart Claude Code. To pull updates later: `/plugin marketplace update test-framework`

A drop-in QA framework for Claude Code. Point it at any web app: it maps the
routes, generates a plain-English test suite, and runs it — through a real
browser for anything a user would click through, and through `curl` for
`/api/*` endpoints.

## Why

Permission checks like "a normal user must not reach `/admin`" used to be
answered with a `curl` request and a status code. That is fast, but it misses
what actually happens in a browser. A page can send you to `/login` with
client-side JavaScript instead of an HTTP redirect. And a status code often
cannot tell a refusal from a leak at all: a page that says "Access denied" and
a page that dumps every salary can both return `200 OK`. One of those is fine
and one is serious, and only the rendered page says which. So those checks now
run in a real Playwright browser.

That makes a run slower and costs real tokens: a suite of about 90 cases that
used to take ~2 seconds and next-to-no tokens now takes minutes and real
money. Two things keep that honest instead of unbounded:

- **Every case is understood once.** The model reads a page once, compiles
  what it learned into a recipe, and saves it. Every later run replays that
  recipe — it never re-reasons about a page it has already seen.
- **If your project has Playwright installed**, cases get promoted into real
  spec files in your own test runner. After that, the whole suite re-runs
  headless, in your runner, for zero model tokens. `/api/*` cases already
  run this way today, on plain `curl`.

**New here? Read [TRY-IT.md](TRY-IT.md)** — install and use it, in plain language.

## Install

```
/plugin marketplace add D:\web-apps\test-framework
/plugin install test-framework
```

Requires the **Playwright MCP** for browser cases. A bundled `.mcp.json`
declares it; delete that file if you already have the Playwright MCP plugin
installed, to avoid running two copies.

## Use

Three commands.

```
/test-setup                detect the stack, create tests/, log in each role
/test-run                  find pages, write the tests, run them, show the result
/test-report                show the last result again
/test-report --coverage     what has no tests
/test-report --bug <id>     turn a failure into a structured bug report
```

`/test-run` flags: `--changed` (default) `--all` `--feature <name>`
`--only-failing` `--headed` `--fresh` `--allow-destructive`. `--headed` opens
a visible browser window — reach for it when a case fails and you cannot tell
why from the log.

Existing suite from before this change? `tf.sh migrate` converts it to the
new format, keeping ids and history.

Every run ends with a dashboard in the terminal — rendered by `tf.sh`, so it
costs nothing, and printed verbatim rather than re-described:

```
╭─ TEST RUN ── hrms ──────────────────────────────── 14:53:16 ╮
│  94 cases   █████████████████░░░  85%   4.2s                │
│  ✓ pass 80    ✗ fail 12   ! error 2   ○ skip 3              │
│  auth 40/42    rbac 10/12    api 30/40                      │
│  trend  ▄▅▆█▆  85%                                          │
╰─────────────────────────────────────────────────────────────╯

  ⚠  SECURITY - privilege boundary crossed
     RBAC-USER-002   user      → /payroll               200

  REGRESSED since run-20260902-145305.csv
     INV-014         /invoices/new                      404

  ⚠  1 destructive case skipped (--allow-destructive to run)

  → tests/results/run-20260902-145314.csv
  → /test-report --bug RBAC-USER-002
```

Sections appear only when they have content, so a clean run is three lines and a
next step. Security failures are pinned above everything and set the verdict —
91% green while a logged-out visitor can read payroll is not a passing run. Exit
codes gate CI: `0` pass · `1` failures · `2` security failure · `3` couldn't run.
`--json`, `--quiet`, `--ascii` and `--no-color` are available; colour is emitted
only to a real terminal.

## The test file

`tests/testcases.csv` is 8 plain-English columns:

```
id,area,who,what to do,what should happen,priority,status,notes
```

Real generated rows look like this:

```
AUTH-002,admin,nobody,Open /admin without logging in,Should not open - sends me to the login page,high,new,
PERM-USER-002,payroll,normal user,Log in as normal user and open /payroll,Should not open - I am not allowed to see this,high,new,
```

`who` is `nobody`, `normal user`, or `admin`. `priority` is `high`, `medium`,
or `low`. `status` is `new`, `passing`, `failing`, or `skipped`. You can open
this file in a spreadsheet and read every row without translation.

Bookkeeping the framework needs to run — caches, timings, internal state —
lives in `tests/.cache/state.csv`, not in `testcases.csv`. Nobody needs to
read it. One effect worth knowing: a run only touches a row in
`testcases.csv` when that row's result actually changed, so your own edits
and your git history stay clean instead of getting rewritten every run.

## Tiers

Detected automatically at `/test-setup`. **Nothing is ever installed for you.**

| Tier | When | Browser re-runs | Written into your project |
| --- | --- | --- | --- |
| **0** | no test runtime present | replayed through the MCP | **nothing** |
| **1** | your stack's Playwright binding is installed | your own runner | specs + config, in your language |
| **2** | Tier 1 + JUnit XML output | your own runner | Tier 1 + a results adapter |

Tier 0 is the default and is fully supported, not a degraded mode. A Python or
Go project never has Node forced on it; a project with no test runtime at all
still gets a working suite — it just keeps paying browser-agent cost on every
re-run instead of promoting to a zero-token spec file.

## Cost

There is no free tier for browser cases anymore — that is the whole point of
running them in a real browser. What keeps cost bounded:

| Case type | First run | Every run after (Tier 0) | Every run after (Tier 1/2) |
| --- | --- | --- | --- |
| `api` — `/api/*` endpoints, on `curl` | 0 | 0 | 0 |
| `ui` / `auth` / `rbac`, route already modelled | replay a saved recipe (small) | replay a saved recipe (small) | **0** — runs headless in your own test runner |
| `ui` / `auth` / `rbac`, first case on a route | one page model, shared by every case on that route | — | — |

Cost scales with *route* count, not case count: the expensive step is
understanding a page for the first time, and every other case on that page
rides along on the same recipe. Promoting to Tier 1/2 is what turns that
recurring small cost into nothing.

## Safety

- **Production guard** — refuses any non-local `base_url` unless
  `tests/framework.json` sets `"allow_remote": true`. Applies to `curl` runs too.
- **Destructive cases are opt-in** — generated, tagged, and left `skipped` until
  `--allow-destructive`.
- **Credentials stay in `tests/credentials.json`** (gitignored) and never reach
  transcripts, results, specs or reports.
- **Your source is read-only.** The framework writes under `tests/` and appends
  to `.gitignore`. Nothing else.

## `scripts/tf.sh`

The deterministic engine. POSIX `sh` + `awk` + `curl`, run by Claude's own Bash
tool — **not a dependency of your project**. Everything in it exists so the
model doesn't have to do it: CSV querying, route discovery, the RBAC matrix,
HTTP execution, regression diffing, report rendering.

```sh
tf.sh select --status new --priority high --cols id,todo --format plain
tf.sh routes src/ > tests/.cache/routes.txt
tf.sh rbac tests/.cache/routes.txt tests/.cache/privileged.txt
tf.sh run-api
tf.sh help
```

## Progress while it runs

`tf.sh` reports progress on **stderr**, so stdout stays clean for `--json` and
pipes. It picks a renderer for the context rather than pretending one works
everywhere:

| Context | Output |
| --- | --- |
| A real terminal | One in-place bar with counts and ETA, erased before the panel |
| Claude Code, CI, pipes | Throttled plain lines, no carriage returns, **capped at 10 per run** |
| `--quiet` / `--json` / `TF_PROGRESS=0` | Nothing |

```
auth   [####------]   36/89    40%  20.6s
auth   [########--]   72/89    80%  36.8s
rbac   [##########]   89/89   100%  45.6s
```

The cap is a token budget, not a style choice — those lines land in Claude's
context on every run. Ten is about 100 tokens.

**A crossed privilege boundary prints the moment it is found**, in every mode,
so you see it at second 2 rather than second 40. Ordinary failures wait for the
panel.

Every case also updates `tests/.cache/progress`, written atomically. That makes
a run observable from outside it — `tf.sh watch` renders a live bar in a second
terminal, and it is how a backgrounded run or a browser agent reports progress
to something that can actually display it.

## Status

**Implemented and verified end to end** against a purpose-built fixture app:
stack detection, route discovery, RBAC and auth-boundary generation, curl login
with CSRF handling, HTTP execution, the summary panel, progress reporting, cost
projection, and the reporting/coverage commands.

**The browser loop is real, not a plan:** permission checks now navigate,
click, and read the resulting page in a live Playwright browser instead of
issuing a `curl` request — so a refusal and a leak that share a `200 OK` are
told apart by what the page actually says. A case is compiled
into a recipe once and replayed on every later run; on a project with
Playwright installed, cases are promoted into real spec files and re-run
headless for zero tokens.

The JS and Python JUnit→CSV adapters were executed against sample JUnit output
and produce identical, correct results. The Java and .NET adapters were not run
(no JDK or dotnet SDK present).

## Playwright MCP naming

The browser agents declare **both** tool-name prefixes:

- `mcp__playwright__*` — when the bundled `.mcp.json` in this plugin provides the server
- `mcp__plugin_playwright_playwright__*` — when you already have the Playwright MCP plugin installed

Which one applies depends on how Playwright got there. Declaring only one means
the agents silently get no browser tools under the other install, so both are
listed. If you add the MCP under a different server name, add that prefix to
`agents/page-modeler.md` and `agents/test-runner.md`.
