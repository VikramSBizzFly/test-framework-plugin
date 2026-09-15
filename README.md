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
/test-setup --ci            the same, plus a CI workflow for your project
/test-run                   find pages, write tests, run them, show the result
/test-report                show the last result again
/test-report --coverage     what has no tests
/test-report --flakes       cases that flip verdict without a code change
/test-report --bug <id>     turn a failure into a bug report
/test-report --publish      the last result as a shareable page
```

**What `/test-run` runs** — one of these, `--changed` if you say nothing:

```
--changed           only what your last commit touched
--all               the whole suite
--feature <name>    one area, e.g. --feature invoices
--only-failing      just what failed last time
```

**What it adds to the run** — each one is optional:

```
--crawl             open the app to find pages the source didn't reveal
--responsive        check each page at phone, tablet and desktop widths
--a11y              check each page works for a screen-reader user
--security          probe permission boundaries a role sweep can't reach
--allow-destructive also run the tests that delete or cancel things
--fresh             rewrite the tests even if nothing changed
--headed            show the browser instead of running it hidden
```

A full browser run takes minutes, so the whole suite is always an explicit
`--all`. Use `--headed` to watch the browser when a test fails and the log
doesn't say why.

`/test-setup --tier 0` forces the browser-only tier if you don't want specs
written into your project.

## It starts on its own

You don't have to remember the commands. Ask for what you want in plain
language — *"find bugs in my app"*, *"can a normal user see the payroll page?"*,
*"test my API"*, *"what isn't tested?"* — and the plugin picks it up, works out
whether the project is set up yet, and routes to the right command.

**What it does without asking:** check the app is up, detect the stack, discover
routes, and run the `curl` cases. All of that is free.

**What it always asks about first:** a full browser run (it tells you how many
cases and roughly how long), anything destructive, and any non-local target.

It stays out of the way when the request isn't web-app QA — a unit test for one
function, or a question about the test library your project already uses, is not
this plugin's job and it will say so rather than take over.

Two things make this work: a `qa` skill that Claude selects from your wording,
and a `UserPromptSubmit` hook (`hooks/hooks.json`) that adds one line of context
when your prompt mentions testing. The hook is active as soon as the plugin is
installed, prints nothing on prompts that don't match, and never blocks a
prompt. To switch it off, disable the plugin's hooks in `/config`, or delete
`hooks/hooks.json` from the installed copy.

## The workbook

`tests/testcases.xlsx` is where everything lives, and it is the only file you
open. Three sheets:

| Sheet | What's in it |
| --- | --- |
| **Flows** | what the software actually does, end to end: the journey, the code path behind it, what it writes, how it can fail, and which cases cover it |
| **Test Cases** | 8 plain-English columns, plus the live status of each case |
| **Results** | the last run, case by case |

```
id,area,who,what to do,what should happen,priority,status,notes
```

```
AUTH-002,admin,nobody,Open /admin without logging in,Should not open - sends me to the login page,high,new,
PERM-USER-002,payroll,normal user,Log in as normal user and open /payroll,Should not open - I am not allowed to see this,high,new,
```

`who` is `nobody`, `normal user`, or `admin`. `priority` is `high`/`medium`/`low`.
`status` is `new`/`passing`/`failing`/`flaky`/`skipped`. A case goes `flaky` only
after it flips verdict three times with no matching source change; flaky cases
are listed separately and do not set the verdict.

**The plugin keeps it up to date.** After every run each case gets its verdict,
timestamp and evidence path written back, and each flow's status is rolled up
from the cases covering it — `passing` only if they all passed, and **`not
covered`** when nothing tests it at all. That last value is the most useful
column in the file. A verdict that didn't change rewrites nothing, so your git
history stays clean.

**You can edit it.** Change a status, add a note, type a new row and leave the
id blank — the next run reads your edits back in first, and a hand edit always
wins. Nothing you write is deleted by a regeneration.

Underneath, the engine reads a CSV copy in `tests/.cache/` — awk can't read a
ZIP of XML. You never touch it. Writing the workbook needs Python on your
machine; without it the framework falls back to a plain `tests/testcases.csv`
and says so.

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

Exit codes for CI: `0` pass · `1` failures · `2` security failure · `3` couldn't
run. `3` is deliberately separate: an app that never started is not a test
result. `--json`, `--quiet`, `--ascii` and `--no-color` are also available.

## Why a real browser

A status code can't tell a refusal from a leak. A page saying "Access denied" and
a page dumping every salary both return `200 OK`. A page can also redirect you to
`/login` with JavaScript, which `curl` never sees. So permission checks run in a
real browser and read what the page actually says.

That costs tokens. Three things keep it bounded:

- **Each page is understood once.** One agent reads it and writes a compact page
  model; every case on that route is then compiled into a replayable recipe
  without opening a browser again.
- **Each stage runs in its own agent.** Snapshots, DOM, evidence files and
  credentials never enter the main conversation, so the expensive context stays
  small. That isolation *is* the cost model.
- **If your project has Playwright installed**, passing cases are promoted into
  real spec files in your own runner — after that the suite re-runs headless for
  zero tokens. `/api/*` cases already run at zero cost, on plain `curl`.

Cost scales with the number of *pages*, not the number of tests.

## What else it can check

Three optional passes ride on browser cases you are already running:

- **`--a11y`** — from the accessibility tree each page snapshot already returns:
  every input has an accessible name, every control is reachable, heading levels
  don't skip. Not a WCAG audit; the three failures that actually block someone.
- **`--responsive`** — each page at 390, 768 and 1280: horizontal overflow,
  clipped or overlapping text, controls pushed off-screen, a nav that never
  collapses, tap targets too small to hit. Reflow is not a failure — a stacking
  sidebar is the design working.
- **`--security`** — the boundaries a role-by-route sweep can't express: opening
  another account's record by id, reaching an unlinked route, reusing a session
  after logout, and open redirects. **Authorization probing only** — never
  injection, brute force or anything destructive.
- **Visual regression** — opt-in, per page. Worth it where markup is stable and a
  pixel change is the whole risk; a waste on anything driven by live data.

## Tiers

Detected automatically at `/test-setup`. **Nothing is ever installed for you.**

| Tier | When | Browser re-runs | Added to your project |
| --- | --- | --- | --- |
| **0** | no test runtime | replayed via the MCP | **nothing** |
| **1** | your stack's Playwright binding is installed | your own runner | specs + config, in your language |
| **2** | Tier 1 + JUnit XML | your own runner | Tier 1 + a results adapter |

Tier 0 is the default and fully supported, not a degraded mode. A Python or Go
project never gets Node forced on it. In CI, Tier 0 runs the `curl` pass only —
recipe replay needs the Playwright MCP, which a CI runner doesn't have.

## Safety

- **Production guard** — refuses any non-local `base_url` unless
  `tests/framework.json` sets `"allow_remote": true`.
- **Destructive tests are opt-in** — written, tagged, and left `skipped` until
  `--allow-destructive`.
- **Credentials stay in `tests/credentials.json`** (gitignored) and never reach
  transcripts, results, specs, evidence, bug reports or CI workflow files.
- **A human challenge stops the run.** 2FA and CAPTCHA are handed back to you;
  the framework never attempts to solve or bypass one.
- **`--security` probes authorization, nothing else**, and never acts on what it
  reaches — no deleting, modifying or exporting the data a probe exposes.
- **Your source is read-only.** The framework writes under `tests/` and appends to
  `.gitignore`. Nothing else.

## Under the hood

`scripts/tf.sh` is the deterministic engine — POSIX `sh` + `awk` + `curl`, run by
Claude's Bash tool, **not a dependency of your project**. It does everything the
model shouldn't have to: CSV queries, route discovery, the RBAC matrix, HTTP
execution, regression diffing, report rendering.

It is one entry point and a handful of modules under `scripts/lib/`, one per
concern: `store.sh` (the case store), `auth.sh` (sessions), `api.sh` (`run-api`),
`discovery.sh`, `generate.sh`, `report.sh`, `migrate.sh`, `xlsx.sh`, and the
shared `core.sh`/`progress.sh`. Always call `tf.sh`; the modules are not
commands.

```sh
tf.sh select --status new --priority high --cols id,todo --format plain
tf.sh routes src/ > tests/.cache/routes.txt
tf.sh run-api
tf.sh storage-state admin   # cookie jar -> Playwright session
tf.sh xlsx                  # rebuild the workbook
tf.sh xlsx --import         # pull hand edits out of the sheet
tf.sh xlsx --status         # write verdicts back after a run
tf.sh migrate               # force a migration (normally automatic)
tf.sh version
tf.sh help
```

Progress goes to **stderr** (so stdout stays clean for `--json`): a live bar in a
real terminal, throttled plain lines in Claude Code and CI (capped at 10 per run),
nothing under `--quiet`. A crossed privilege boundary prints the moment it's
found. `tf.sh watch` renders a live bar in a second terminal.

Above the engine sit **12 skills** — the rules for each stage, loaded only when
that stage runs — and **18 agents**, one per stage:

| Stage | Agent |
| --- | --- |
| detect the stack | `stack-detector` |
| map the flows through the code | `flow-mapper` |
| log in, both session formats | `login-broker` |
| group routes into features | `test-explorer` |
| find routes a glob missed | `route-crawler` |
| write the cases | `case-author`, `api-case-author` |
| model a route, once | `page-modeler` |
| compile cases to recipes, no browser | `test-compiler` |
| replay in a browser | `test-runner` |
| accessibility, responsive, visual, authorization | `a11y-auditor`, `responsive-auditor`, `visual-reviewer`, `security-prober` |
| diagnose a failure | `test-triager`, `flake-analyst` |
| promote to native specs | `spec-writer` |
| report | `bug-reporter`, `coverage-analyst` |
| CI | `ci-wirer` |

Every agent returns a fixed, terse block — verdict rows, file paths, counts —
never a snapshot or a file's contents.

## Versioning

The version lives in `.claude-plugin/plugin.json`; `tf.sh version` prints it,
and [CHANGELOG.md](CHANGELOG.md) says what changed. Semver, where "breaking"
means *your existing suite stops running*:

- **MAJOR** — you have to do something: the `testcases.csv` schema changed, a
  `tf.sh` subcommand or flag was removed or renamed, or your suite needs
  `tf.sh migrate` before it runs again.
- **MINOR** — new agents, commands, skills, flags or subcommands. Existing
  suites keep working untouched.
- **PATCH** — fixes and wording. No new surface.

## Status

Verified end to end against a purpose-built fixture app (`example/demo-app.py`):
stack detection, route discovery, RBAC and auth-boundary generation, login with
CSRF handling, the cookie-jar-to-browser-session conversion, HTTP execution, the
summary panel and its exit codes, progress reporting, and the reporting commands.

The browser loop is real, not a plan — permission checks navigate, click, and read
the live page. The JS and Python JUnit→CSV adapters were run against sample
output; the Java and .NET adapters were not (no JDK or dotnet SDK available). The
`--a11y` and `--security` passes are new: the rules and agents are in place, but
they have not yet been run end to end against the fixture.

## Playwright MCP naming

The browser agents declare both tool prefixes, since either can apply depending on
how Playwright got installed:

- `mcp__playwright__*` — the bundled `.mcp.json` provides the server
- `mcp__plugin_playwright_playwright__*` — you already have the Playwright MCP plugin

If you add the MCP under a different server name, add that prefix to every agent
that drives a browser: `page-modeler`, `test-runner`, `login-broker`,
`route-crawler`, `a11y-auditor` and `security-prober`.
