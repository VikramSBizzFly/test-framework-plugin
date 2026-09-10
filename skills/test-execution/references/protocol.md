# Execution protocol

## Storage state, not click-through login

Before the first `nav` in a route group, load `tests/.auth/<role>.json` as
the Playwright MCP's storage state for that browser session. This is what
lets recipes `nav` straight to the target route instead of clicking through a
login form — see `test-compilation`'s direct-navigation rule. If the file is
missing, the role has no browser session; report the group as skipped rather
than running it logged out.

## Route batching

One browser session per route group: navigate/login once, then replay every
case for that route+role before moving to the next group. Switching route
inside a session just means another `nav` — the session and storage state
stay open. This is what keeps the MCP call count near *(routes × roles)*,
not *(cases)*.

## The locator cache

`tests/.cache/locators/<route>.json` maps `<type>:<name>` → MCP element
`ref`, e.g. `{"button:Sign in": "e14", "textbox:Email": "e12"}`. It is seeded
from the page model the first time a route is replayed in a session.

- A recipe step resolves its element from this cache and acts on the `ref`
  directly — **no snapshot** for that step.
- If a `ref` fails to resolve (stale DOM), take exactly one fresh
  `browser_snapshot`, re-resolve every name in the cache from it, retry the
  step once, and persist the refreshed cache.
- Never snapshot proactively "to be safe." A snapshot you didn't need is the
  exact cost this framework exists to avoid.

## MCP call sequence, per case

```
browser_navigate  -> nav's path (storage state already loaded)
[locator-cache lookups; browser_snapshot only on a cache miss, see above]
act steps          -> click / fill / select / check, via cached refs
browser_snapshot    -> once, right before judging the expect line(s)
assert              -> read the snapshot for the expect condition(s)
```

**Pass/fail is judged from the accessibility snapshot, never from a
screenshot alone.** A screenshot cannot tell you an element's accessible
name, role or state — it can only corroborate what the snapshot already
proved. **No snapshot on success, ever**: if the assertion snapshot passes,
discard it — don't save it, don't return it, don't describe it. Snapshots
and screenshots are failure evidence only; save them under
`tests/evidence/<id>/` and return just the path.

## Ambient failure detection

A case fails even when its own `expect` passes if, during the recipe:

- an uncaught console error was logged (`browser_console_messages`)
- a network request came back 4xx/5xx that the case didn't intend to test
  (`browser_network_requests`)
- an unhandled promise rejection occurred

Check these once per case, after the assertion, not per step. `failure_class`
for these is `ambient`, distinct from `assertion` (the `expect` failed) and
`infra` (navigation/timeout/element never resolved).

## Cleanup registry

A recipe step that creates a record (an id echoed back in a URL, a snapshot
row, a response) appends `<id> <route> <created-id>` to
`tests/.cache/cleanup/<run-id>.txt`. After the batch, delete what was
created, in reverse order, before reporting done. An untracked created
record is data pollution the next run will trip over.

## Retry-once and the circuit breaker

A failing case is replayed exactly one more time before its verdict is
final. Same verdict twice → `status=failing`. A flip (fail then pass, or
vice versa) still lands `status=passing` on a final pass, but increment
`flake_count` and record the flip — do not silently keep the pass as if
nothing happened.

Abort the **whole batch** after 3 consecutive failures (across retries).
A down app, a broken build, or a bad deploy must cost 3 cases, not the
suite — report the abort point and mark the remainder `skipped`, not `failing`.

## Session re-check, not just at the start

A group failing on `expect url /login` (or every case in a group erroring
"no session") is not proof the app broke — the role's storage state can go
stale mid-run even though it was valid at group 1. Before marking a whole
group `failing` on that symptom, re-run `tf.sh login <role>`, reload storage
state, and retry the group once. Only report the app as broken if the group
still fails with a fresh session.
