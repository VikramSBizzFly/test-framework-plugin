# The four probes

> `tf.sh` = `"$CLAUDE_PLUGIN_ROOT/scripts/tf.sh"` (not on PATH).

Each probe below is judged the same way: navigate as the role, then read the
rendered page. A `200` proves nothing either way.

## 1. IDOR — someone else's record

Take an id the role does not own and open it directly: `/invoices/7` as the user
who owns `/invoices/3`. Vary the id form the app actually uses — sequential
integers are the common case, but a UUID that appears in another role's page is
the same bug.

- **FAIL** — the other account's data renders.
- **PASS** — a refusal, a 404, or a redirect to the role's own scope.
- Evidence: the route, the role, and *which field* proved it was the wrong
  record's data. Not the field's value.

## 2. Forced browsing — the route with no link

Routes that exist but are not linked for this role: the admin page missing from
the nav, the export endpoint behind a hidden button, an old route left routable.
`tests/.cache/privileged.txt` and `routes.txt` together are the candidate list.

- **FAIL** — the page renders for a role the guard was supposed to stop.
- **PASS** — refused, however it is phrased.

## 3. Session reuse after logout

Log out, then replay the previous session's storage state against a protected
route. A server that only clears a client-side cookie leaves the session valid.

- **FAIL** — the protected route still renders with the stale session.
- Evidence: the logout step, then the route that still worked.

## 4. Open redirect

A `?next=` / `?return_to=` / `?redirect=` parameter pointed at an off-origin
URL, e.g. `/login?next=https://example.invalid/`.

- **FAIL** — the app navigates off-origin after the flow completes.
- **PASS** — it ignores the parameter, or only accepts a relative path.

## Judging, and what not to do

A refusal can be a redirect, a banner, an empty state, or a `200` whose body
says "Access denied" — `expect any-of` and `expect not-text` exist for exactly
this shape. See `skills/test-compilation/references/grammar.md`.

Re-run once before recording a crossed boundary: a single sample cannot
distinguish a leak from a session that had expired into someone else's state.

Never escalate a finding into an exploit. You demonstrate that a page rendered;
you do not enumerate every record, export the data, or chain the finding into a
write. Stop at the first page that proves it, and redact what it contained.
