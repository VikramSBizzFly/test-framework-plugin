# How to install and use this

You do **not** need to install Node, Python, npm, or anything else.

---

## Install it

In Claude Code, run these two lines:

```
/plugin marketplace add D:\web-apps\test-framework
/plugin install test-framework
```

That's it. You now have the `/test-*` commands.

---

## Use it on your project

### 1. Open your project and set it up

```
/test-setup
```

This looks at your project, works out what language it is, creates a
`tests/` folder, and logs in as each user role you give it. It will **not**
install anything into your project.

### 2. Put in a login

Open `tests/credentials.json` and fill in a test account:

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

Use a **test** account, never a real customer one. This file is added to
`.gitignore` automatically, so it will not be committed.

Add one entry per kind of user you have. The more roles you list, the more
permission problems it can find. Run `/test-setup` again after you fill this
in, so it can log in with the accounts you just added.

### 3. Start your app, then run the tests

Make sure your app is running first, then:

```
/test-run
```

This finds your pages, writes test cases into `tests/testcases.csv`, runs
them, and prints a result box. Most checks open a real browser window in the
background and click through your app the way a real user would, so this
takes minutes, not seconds, and it does cost some money in model usage. In
return it catches things a simple web request cannot: a page that quietly
redirects you away with JavaScript, or a broken page that says "Access
denied" but still answers "OK" underneath.

You can open `tests/testcases.csv` in Excel and read every row in plain
English. Delete anything that looks wrong.

---

## What the result means

You get a box like this:

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
| **ran with no session** | The login did not work, so those results mean nothing. Not a real pass. |

The last line always tells you what to do next.

---

## If something goes wrong

**"unreachable"** — your app is not running. Start it, then try again.

**"refusing to run against remote host"** — this is on purpose. It only tests
`localhost` unless you allow otherwise. Never point it at a live site with real
customers.

**"login failed"** — check the `path` and `success_indicator` in
`tests/credentials.json`, then run `/test-setup` again. It opens a real
browser to log in, so most login pages work even if they need JavaScript.

**"ran with no session"** — read this one carefully. It means the tests ran
while logged out. Logged-out users are blocked from everything anyway, so the
tests *look* like they passed but proved nothing. Fix the login and run again.

**Runs feel slow or costly** — that is expected now. Most checks click through
a real browser instead of just sending a web request. Two things keep it from
getting out of hand: once the framework understands a page, it saves that and
never re-figures it out; and if your project already has Playwright installed,
your tests get turned into real test files that then run for free, with no
browser window and no cost, every time after that.

**Already had a test suite from before?** Run `tf.sh migrate` to convert it to
the new format. It keeps your ids and your history.

---

## All the commands

There are three.

| Command | What it does |
| --- | --- |
| `/test-setup` | Set up a project: detect the stack, create `tests/`, log in as each role |
| `/test-run` | Find pages, write the tests, run them, show the result |
| `/test-report` | Show the last result again |
| `/test-report --coverage` | Show what has no tests |
| `/test-report --bug AUTH-003` | Turn a failure into a bug report |

`/test-run` also takes these flags: `--changed` (the default), `--all`,
`--feature <name>`, `--only-failing`, `--headed`, `--fresh`,
`--allow-destructive`.

`--headed` opens a visible browser window so you can watch what happens.
Reach for it when a test fails and you cannot tell why from the result box.

---

## Two things worth knowing

**It understands each page once.** The first time it sees a page, it works out
how the page behaves and saves that. Every run after that reuses what it
already learned instead of figuring the page out again.

**It will not break anything.** Tests that delete things are written but left
switched off. You have to ask for them on purpose:

```
/test-run --allow-destructive
```

---

## Want something to practise on?

`example/demo-app.py` is a tiny web app with a permission bug hidden in it.
Point the framework at it and see if it finds the bug. (That demo needs Python;
the framework itself does not.)
