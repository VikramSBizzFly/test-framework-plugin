---
name: test-security
description: Decide whether the app actually refused someone, and probe the authorization boundaries a role-by-route matrix cannot express. Use when generating or judging a permission case, when running the security pass, or when a run's verdict turns on whether protected content rendered.
---

# Security

> `tf.sh` = `"$CLAUDE_PLUGIN_ROOT/scripts/tf.sh"` (not on PATH).

This framework opens a real browser for one reason, and it is this one.

**A refusal and a leak both return `200`.** A page reading "Access denied" and a
page dumping every salary are indistinguishable by status code, and a guard
implemented in JavaScript does not exist for `curl` to hit at all. So the
question is never what the response code said. It is: **did the protected
content actually render?**

That is why a permission check is `type=page` and never `type=api`, however
tempting the zero-token price is. A false pass here costs more than every token
it saved.

## Two layers

**The matrix, free.** `tf.sh rbac routes.txt privileged.txt` sweeps every role
against every route and generates the `AUTH-*`, `API-*` and `PERM-<ROLE>-*`
families. Give it a real `privileged.txt` — without one it falls back to a name
heuristic and says so. This cheap pass is what makes hundreds of permission
cases correct rather than guessed.

**The probes, deliberate.** Four boundaries the matrix cannot express: IDOR,
forced browsing, session reuse after logout, and open redirect. Delegate these
to the `security-prober` agent, one call per feature. Worked examples and the
evidence each verdict needs: `references/probes.md`.

## Verdict and reporting

Tag these cases `tags=security`. `tf.sh summary` pins them above everything else
and exits **`2`**, distinct from an ordinary failure. A 91% green run while a
logged-out visitor can read payroll is not a passing run, and the panel is built
to say so.

Evidence records **that** protected content rendered — never the content.
Redact on write: a leaked salary pasted into `tests/evidence/` has simply moved
the leak somewhere else.

## Scope — authorization only

Probe what a user is allowed to reach. **Never** send an injection payload,
brute-force a login, fuzz an input, run anything that degrades the service, or
attempt a CAPTCHA or 2FA challenge. Never act on what you reached: no deleting,
modifying or exporting the data a probe exposed.

And never run any of this against a non-local `base_url`. `tf.sh preflight`
refuses one without `allow_remote`, and that refusal is a feature.
