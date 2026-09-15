# Turning a failure into a bug

> `tf.sh` = `"$CLAUDE_PLUGIN_ROOT/scripts/tf.sh"` (not on PATH).

Bugs live in **`tests/bug-report.xlsx`** — one Bugs sheet in the team's
bug-sheet columns — with `tests/.cache/bugs.csv` beneath it. The `bug-reporter`
agent records them, so the evidence files stay out of the main conversation.

## Only a confirmed app bug becomes a bug

After a run, every failing case is triaged. **Only `VERDICT app-bug` is handed to
`bug-reporter`.** A `stale-test` (the app changed on purpose), an `environment`
failure (the server was down) and a `flake` (it flips on its own) are not
defects in the app — recording them trains a team to stop reading the sheet.
`/test-report --bug <id>` does the same thing on demand.

## Who fills in what

| Column | Filled by |
| --- | --- |
| Bug No, Module, Steps to Reproduce, Expected Result, Actual Result, Test data | the engine, from the case |
| Status(QA) | the engine, `Open`, when the bug is raised |
| Reporter, Environment, Access Link, found date | the engine: git user, base URL host, base URL + route, today |
| **Bug Description, Severity, Priority, QA Comments** | **the agent** — this is the judgement |
| Bug Link, Dev Comment, later changes to Status(QA) | **people** |

```sh
tf.sh bug from <id> \
  "Bug Description=Payroll renders for a logged-out visitor" \
  Severity=Critical Priority=High \
  "QA Comments=No role check on the payroll handler; app.py:96"
```

- **Title the behaviour, not the case**: "payroll renders for a logged-out
  visitor", not "RBAC-USER-002 failed". The first is a bug someone can act on;
  the second is a row id.
- **Idempotent.** A case with an open bug gets it updated, not duplicated. A
  Closed or Fixed bug whose case fails again becomes **Reopened**. A bug a
  person marked **Not a Bug** is left alone — a person decided, and a run does
  not overrule them.
- `tf.sh bug list [--status Open]` shows what is recorded;
  `tf.sh bug set <BUG-NNN> "Bug Link=https://..."` records a filed issue.

## Severity

| Severity | When |
| --- | --- |
| **Critical** | a security failure — an `AUTH-` or `PERM-` case, or a `security-prober` finding |
| **High** | a core flow is broken with no workaround |
| **Medium** | wrong, but a user can work around it |
| **Low** | cosmetic, copy, or responsive layout |

## Filing it

Offer a `gh issue create` command built from the bug. **Offer it; do not run
it.** Filing into someone's tracker is their call, not yours. When it is filed,
record the link with `tf.sh bug set <BUG-NNN> "Bug Link=<url>"`.

## After a run

The run panel ends with how many bugs are open, and names any open bug whose
case now passes — `BUG-004 may be fixed: AUTH-002 now passes -- retest it`.
That is the retest to do next; it does not change the bug's status, because
closing a bug is a person's call.

## Redaction

`tf.sh bug` refuses any value containing a password or token from
`credentials.json`. It cannot see a session cookie in a network capture or a
leaked personal record, so everything in `## Redaction detail` of
`prose-coverage-publishing.md` still applies — and a bug sheet is the file most
likely to be pasted somewhere public. Roles, routes, status codes and timings are
safe; usernames, passwords, tokens, cookie values and the records a leak exposed
are not.

If the evidence cannot be quoted without leaking, describe it and cite the path.
For a security finding, say *that* protected content rendered and which field
proved it, never the value.
