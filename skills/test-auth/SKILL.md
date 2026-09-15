---
name: test-auth
description: Establish and maintain a session for each role, and keep credentials out of everything the framework writes. Use during /test-setup, when a session expires mid-run, when a role has no storage state, or whenever you are about to handle a username, password, cookie or token.
---

# Auth

> `tf.sh` = `"$CLAUDE_PLUGIN_ROOT/scripts/tf.sh"` (not on PATH).

Without a session the permission cases are meaningless: a logged-out visitor is
refused everything, so every case "passes" and the report is green while the app
may be wide open. That failure is silent, which is why this skill exists.

Delegate the work to the `login-broker` agent, one call per role — it is the
only thing that should touch a credential.

## Two artifacts, and a run needs both

| File | Written by | Read by |
| --- | --- | --- |
| `tests/.auth/<role>.cookies` | `tf.sh login <role>` | `tf.sh run-api`, `tf.sh preflight` — curl |
| `tests/.auth/<role>.json` | `tf.sh storage-state <role>` | `page-modeler`, `test-runner`, every browser case |

A role with the jar but no storage state looks logged in to the API pass and
logged out to the browser pass. Always produce both; `tf.sh storage-state`
converts one to the other, `HttpOnly` cookies included.

## Rules

**`who: nobody` is logged out on purpose** — that is the test, not a missing
session. For any other role with no session file, the group is `ERROR` with
`failure_class=infra`. Never silently replay it logged out.

**Sessions expire mid-run.** A wave of same-role failures is an expiry, not the
app breaking. Re-login **once per role per run**, reload the storage state and
continue; blame the app only when a fresh session still fails.

**Stop at a human challenge.** 2FA, a CAPTCHA, an SSO consent screen — hand it
back and say what the person must do. Never try to solve or bypass one.

**Verify before trusting.** A session that was never checked against a protected
route is worse than none, because the run reports green. `tf.sh preflight` sends
one real request per role, with that role's session, to `login.session_probe`
(or `roles.<role>.probe`, falling back to `login.success_indicator`). A role is
alive only on a 2xx that is not a login form. A dead role with credentials is
logged in again once; anything still dead exits 3. If the probe page looks the
same logged out, preflight says UNVERIFIABLE — point `session_probe` at a page
that needs a login.

## Credentials

They live in `tests/credentials.json`, which is gitignored, and they go nowhere
else — not a transcript, a recipe, a spec, a result row, an evidence file, a bug
report, a workflow file or an Artifact. Recipes reference `$role.username` /
`$role.password`; specs load storage state and never perform a login. Redact on
write, not on display: if a credential reaches a file, the bug is in whatever
wrote it.

Never echo a password, cookie, token or storage-state body — not even inside a
shell command you run. Name the file instead.

The login procedure, the CSRF token names `tf.sh login` knows, the browser
fallback and the storage-state shape are in `references/login-flows.md`.
