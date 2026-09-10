# test-framework

A QA framework for Claude Code. Point it at any web app: it finds the pages,
writes a plain-English test suite, and runs it — in a real browser for anything
a user would click through, and with `curl` for `/api/*` endpoints.

Works with any stack. Nothing is installed into your project.

## Install

```
/plugin marketplace add VikramSBizzFly/test-framework-plugin
/plugin install test-framework@test-framework
```

Restart Claude Code. To update later: `/plugin marketplace update test-framework`

Browser tests need the **Playwright MCP**. A bundled `.mcp.json` declares it —
delete that file if you already have the Playwright MCP plugin, so you don't run
two copies.

New here? **[TRY-IT.md](TRY-IT.md)** walks through it in plain language.

## Commands

```
/test-setup                 detect the stack, create tests/, log in as each role
/test-run                   find pages, write tests, run them, show the result
/test-report                show the last result again
/test-report --coverage     what has no tests
/test-report --bug <id>     turn a failure into a bug report
```

`/test-run` flags: `--changed` (default) `--all` `--feature <name>`
`--only-failing` `--headed` `--fresh` `--allow-destructive`.

Use `--headed` to watch the browser when a test fails and the log doesn't say why.

## The test file

`tests/testcases.csv` — 8 plain-English columns you can open in a spreadsheet:

```
id,area,who,what to do,what should happen,priority,status,notes
```

```
AUTH-002,admin,nobody,Open /admin without logging in,Should not open - sends me to the login page,high,new,
PERM-USER-002,payroll,normal user,Log in as normal user and open /payroll,Should not open - I am not allowed to see this,high,new,
```

`who` is `nobody`, `normal user`, or `admin`. `priority` is `high`/`medium`/`low`.
`status` is `new`/`passing`/`failing`/`skipped`.

Internal bookkeeping lives in `tests/.cache/`, not in your CSV. A run only edits
a row when its result actually changed, so your git history stays clean.

## What a run looks like

```
╭─ TEST RUN ── hrms ──────────────────────────────── 14:53:16 ╮
│  94 cases   █████████████████░░░  85%   4.2s                │
│  ✓ pass 80    ✗ fail 12   ! error 2   ○ skip 3              │
╰─────────────────────────────────────────────────────────────╯

  ⚠  SECURITY - privilege boundary crossed
     RBAC-USER-002   user      → /payroll               200

  → /test-report --bug RBAC-USER-002
```

A clean run is three lines and a next step. Security failures are pinned at the
top and set the verdict — 91% green while a logged-out visitor can read payroll
is not a passing run.

Exit codes for CI: `0` pass · `1` failures · `2` security failure · `3` couldn't run.
`--json`, `--quiet`, `--ascii` and `--no-color` are also available.

## Why a real browser

A status code can't tell a refusal from a leak. A page saying "Access denied" and
a page dumping every salary both return `200 OK`. A page can also redirect you to
`/login` with JavaScript, which `curl` never sees. So permission checks run in a
real browser and read what the page actually says.

That costs tokens. Two things keep it bounded:

- **Each page is understood once.** The model reads it, saves a recipe, and every
  later run replays the recipe instead of re-reasoning.
- **If your project has Playwright installed**, cases are promoted into real spec
  files in your own runner — after that the suite re-runs headless for zero
  tokens. `/api/*` cases already run at zero cost, on plain `curl`.

Cost scales with the number of *pages*, not the number of tests.

## Tiers

Detected automatically at `/test-setup`. **Nothing is ever installed for you.**

| Tier | When | Browser re-runs | Added to your project |
| --- | --- | --- | --- |
| **0** | no test runtime | replayed via the MCP | **nothing** |
| **1** | your stack's Playwright binding is installed | your own runner | specs + config, in your language |
| **2** | Tier 1 + JUnit XML | your own runner | Tier 1 + a results adapter |

Tier 0 is the default and fully supported, not a degraded mode. A Python or Go
project never gets Node forced on it.

## Safety

- **Production guard** — refuses any non-local `base_url` unless
  `tests/framework.json` sets `"allow_remote": true`.
- **Destructive tests are opt-in** — written, tagged, and left `skipped` until
  `--allow-destructive`.
- **Credentials stay in `tests/credentials.json`** (gitignored) and never reach
  transcripts, results, specs or reports.
- **Your source is read-only.** The framework writes under `tests/` and appends to
  `.gitignore`. Nothing else.

## Under the hood

`scripts/tf.sh` is the deterministic engine — POSIX `sh` + `awk` + `curl`, run by
Claude's Bash tool, **not a dependency of your project**. It does everything the
model shouldn't have to: CSV queries, route discovery, the RBAC matrix, HTTP
execution, regression diffing, report rendering.

```sh
tf.sh select --status new --priority high --cols id,todo --format plain
tf.sh routes src/ > tests/.cache/routes.txt
tf.sh run-api
tf.sh migrate      # convert a suite from an older version
tf.sh help
```

Progress goes to **stderr** (so stdout stays clean for `--json`): a live bar in a
real terminal, throttled plain lines in Claude Code and CI (capped at 10 per run),
nothing under `--quiet`. A crossed privilege boundary prints the moment it's
found. `tf.sh watch` renders a live bar in a second terminal.

## Status

Verified end to end against a purpose-built fixture app: stack detection, route
discovery, RBAC and auth-boundary generation, login with CSRF handling, HTTP
execution, the summary panel, progress reporting, and the reporting commands.

The browser loop is real, not a plan — permission checks navigate, click, and read
the live page. The JS and Python JUnit→CSV adapters were run against sample
output; the Java and .NET adapters were not (no JDK or dotnet SDK available).

## Playwright MCP naming

The browser agents declare both tool prefixes, since either can apply depending on
how Playwright got installed:

- `mcp__playwright__*` — the bundled `.mcp.json` provides the server
- `mcp__plugin_playwright_playwright__*` — you already have the Playwright MCP plugin

If you add the MCP under a different server name, add that prefix to
`agents/page-modeler.md` and `agents/test-runner.md`.
