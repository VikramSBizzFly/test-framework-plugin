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

Everything lands in **`tests/testcases.xlsx`** — open it in Excel. Three tabs:
**Flows** (what your software actually does, step by step, and whether anything
tests it), **Test Cases** (every check, in plain English, with its status), and
**Results** (how the last run went).

You can edit it. Change a status, write a note, or type a new row and leave the
id blank — the next run picks your changes up and keeps them.

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
| **flaky** | Passes sometimes and fails other times, with nothing changed. Listed on its own, and not counted for or against you. |

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

**"has a cookie jar but no browser session"** — the login half-worked: good
enough for simple checks, not for the browser ones. Run `/test-setup` again. Do
not ignore it, or the browser checks will run logged out and look like they
passed.

**"ran with no session"** — read this one carefully. The tests ran while logged
out. Logged-out users are blocked from everything anyway, so the tests *look* like
they passed but proved nothing. Fix the login and run again.

**Runs feel slow or costly** — expected. Most checks click through a real browser.
Two things keep it in hand: once the framework understands a page it saves that and
never re-figures it out; and if your project already has Playwright installed, your
tests become real test files that run for free, headless, every time after that.

**Had a test suite from an older version?** Run `tf.sh migrate` to convert it. It
keeps your ids and history, and moves you to the Excel workbook.

**No Excel file appeared?** Writing one needs Python on your computer. Without
it everything still works — your tests just stay in `tests/testcases.csv`.

---

## All the commands

| Command | What it does |
| --- | --- |
| `/test-setup` | Set up a project: detect the stack, create `tests/`, log in as each role |
| `/test-setup --ci` | The same, and write a workflow so the tests run on every pull request |
| `/test-run` | Find pages, write the tests, run them, show the result |
| `/test-report` | Show the last result again |
| `/test-report --coverage` | Show what has no tests |
| `/test-report --flakes` | Show the tests that keep changing their mind |
| `/test-report --bug AUTH-003` | Turn a failure into a bug report |
| `/test-report --publish` | Put the last result on a page you can share |

**How much to run.** Pick one; it uses `--changed` if you say nothing:

| Flag | What it runs |
| --- | --- |
| `--changed` | Only what your last commit touched |
| `--all` | Everything |
| `--feature invoices` | One area of the app |
| `--only-failing` | Just what failed last time |

**Anything else you want it to do:**

| Flag | What it adds |
| --- | --- |
| `--headed` | Opens a visible browser so you can watch |
| `--crawl` | Clicks around the app to find pages the code didn't mention |
| `--a11y` | Checks each page can be used with a screen reader |
| `--responsive` | Checks each page on a phone, a tablet and a desktop screen |
| `--security` | Tries harder to get at pages you shouldn't be able to see |
| `--allow-destructive` | Also runs the tests that delete things |
| `--fresh` | Rewrites the tests even if nothing changed |

`--headed` is the one to reach for when a test fails and you can't tell why from
the result box.

---

## Seeing what your software does

Ask it to *"map the flows"* and it reads your code and writes down what the
software actually does — log in, create an invoice, run payroll — with the steps,
what each one saves, and how each one can fail. That goes in the **Flows** tab.

The column worth looking at is **status**. A flow marked *not covered* is
something your software does that nothing tests.

---

## The extra checks, in plain words

**`--a11y`** asks: could someone using a screen reader actually use this page?
It checks three things that stop people outright — every box has a label, every
button can be reached, and the headings run in order. It is nearly free, because
it reads something the browser already handed over.

**`--responsive`** opens each page at phone, tablet and desktop size and looks
for things that are actually broken — a page that scrolls sideways, text cut off
or written over itself, a button pushed off the screen, a menu that never turns
into a hamburger, tap targets too small for a thumb. A page *rearranging* itself
on a phone is not a bug, and it won't report one.

**`--security`** goes looking for pages you should not be able to open: someone
else's record by changing a number in the address, a page missing from your menu
but still reachable, a session that still works after you log out. It only ever
*looks*. It never deletes, changes or takes anything, and it never attacks your
login.

Both are optional. Ask for them when you want them:

```
/test-run --a11y
/test-run --responsive
/test-run --security
```

---

## You can just ask

You don't have to remember the commands. Say what you want — *"find bugs in my
app"*, *"can a normal user see the payroll page?"*, *"what isn't tested?"* — and
it works out the rest.

It does the quick, free checks straight away, then tells you how long the slow
part will take and waits for you to say yes. It won't hijack a question that
isn't about testing a website.

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
