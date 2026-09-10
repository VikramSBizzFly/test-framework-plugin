# How to install and use this

You do **not** need to install Node, Python, npm, or anything else.

---

## 1. Install it

In Claude Code:

```
/plugin marketplace add VikramSBizzFly/test-framework-plugin
/plugin install test-framework@test-framework
```

Restart Claude Code. You now have the `/test-*` commands.

---

## 2. Set up your project

Open your project and run:

```
/test-setup
```

It looks at your project, works out what language it is, and creates a `tests/`
folder. It will **not** install anything into your project.

---

## 3. Add a login

Open `tests/credentials.json` and fill in test accounts:

```json
{
  "base_url": "http://localhost:3000",
  "roles": {
    "admin": { "username": "admin@example.com", "password": "..." },
    "user":  { "username": "user@example.com",  "password": "..." }
  },
  "login": { "path": "/login", "success_indicator": "/dashboard" }
}
```

Use **test** accounts, never real customer ones. This file is gitignored
automatically, so it won't be committed.

Add one entry per kind of user you have — the more roles you list, the more
permission problems it can find. Then run `/test-setup` again so it can log in
with the accounts you just added.

---

## 4. Start your app, then run the tests

With your app running:

```
/test-run
```

It finds your pages, writes test cases into `tests/testcases.csv`, runs them, and
prints a result box.

Most checks open a real browser in the background and click through your app like
a real user would. That takes minutes, not seconds, and costs some model usage. In
return it catches what a simple web request can't: a page that redirects you away
with JavaScript, or a broken page that says "Access denied" while still answering
"OK" underneath.

You can open `tests/testcases.csv` in Excel and read every row in plain English.
Delete anything that looks wrong.

---

## Reading the result

```
╭─ TEST RUN ── myapp ───────────────────── 15:41 ╮
│  94 cases   █████████████████░░░  85%   4.2s   │
│  ✓ pass 80    ✗ fail 12   ! error 2  ○ skip 3  │
╰────────────────────────────────────────────────╯

  ⚠  SECURITY - privilege boundary crossed
     RBAC-USER-002   user  → /payroll        200

  → /test-report --bug RBAC-USER-002
```

| Word | Meaning |
| --- | --- |
| **pass** | Worked. |
| **fail** | Did not work. Something is wrong. |
| **error** | Could not even try. Usually the app was down. |
| **skip** | On purpose. Usually a test that deletes things. |

Headings that can appear underneath:

| Heading | Meaning |
| --- | --- |
| **SECURITY** | Someone can open a page they should not. Fix this first. |
| **REGRESSED** | This used to work and now it does not. You just broke it. |
| **FIXED** | This used to fail and now it works. |
| **ran with no session** | The login didn't work, so those results mean nothing. Not a real pass. |

The last line always tells you what to do next.

---

## If something goes wrong

**"unreachable"** — your app isn't running. Start it and try again.

**"refusing to run against remote host"** — on purpose. It only tests `localhost`
unless you allow otherwise. Never point it at a live site with real customers.

**"login failed"** — check `path` and `success_indicator` in
`tests/credentials.json`, then run `/test-setup` again. It logs in through a real
browser, so most login pages work even if they need JavaScript.

**"ran with no session"** — read this one carefully. The tests ran while logged
out. Logged-out users are blocked from everything anyway, so the tests *look* like
they passed but proved nothing. Fix the login and run again.

**Runs feel slow or costly** — expected. Most checks click through a real browser.
Two things keep it in hand: once the framework understands a page it saves that and
never re-figures it out; and if your project already has Playwright installed, your
tests become real test files that run for free, headless, every time after that.

**Had a test suite from an older version?** Run `tf.sh migrate` to convert it. It
keeps your ids and history.

---

## All the commands

| Command | What it does |
| --- | --- |
| `/test-setup` | Set up a project: detect the stack, create `tests/`, log in as each role |
| `/test-run` | Find pages, write the tests, run them, show the result |
| `/test-report` | Show the last result again |
| `/test-report --coverage` | Show what has no tests |
| `/test-report --bug AUTH-003` | Turn a failure into a bug report |

`/test-run` flags: `--changed` (the default), `--all`, `--feature <name>`,
`--only-failing`, `--headed`, `--fresh`, `--allow-destructive`.

`--headed` opens a visible browser so you can watch. Use it when a test fails and
you can't tell why from the result box.

---

## Two things worth knowing

**It understands each page once.** The first time it sees a page it works out how
that page behaves and saves it. Every run after reuses what it learned.

**It won't break anything.** Tests that delete things are written but switched off.
You have to ask for them:

```
/test-run --allow-destructive
```

---

## Want something to practise on?

`example/demo-app.py` is a tiny web app with a permission bug hidden in it. Point
the framework at it and see if it finds the bug. (The demo needs Python; the
framework itself does not.)
