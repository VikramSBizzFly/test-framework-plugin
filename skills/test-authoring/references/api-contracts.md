# Generating `api` cases from a contract

> `tf.sh` = `"$CLAUDE_PLUGIN_ROOT/scripts/tf.sh"` (not on PATH).

`type=api` cases run on plain `curl` via `tf.sh run-api` — zero tokens, every
run, forever. They are the cheapest coverage in the framework, and without a
contract they are only what `tf.sh rbac` guesses from route names. Delegate this
to the `api-case-author` agent.

## Where the contract is

In order of preference: `openapi.json` / `openapi.yaml` / `swagger.*`; a
generated schema route (`/openapi.json`, `/swagger/v1/swagger.json`); then the
route handlers already listed in `tests/.cache/routes.txt`. Use glob and grep —
do not read a source tree to rediscover what discovery already extracted.

## What to extract, per endpoint

Method, path, path and query parameters, required body fields and their types,
and whether the endpoint requires authentication. Nothing else; response schemas
are not worth a case until something asserts on them.

## The four cases worth generating

Per endpoint, deliberately, not one per field:

1. **Happy path** — valid input, expected to succeed.
2. **No session**, when the endpoint requires auth — tag it `tags=refused`.
3. **A required field missing.**
4. **One wrong-type or out-of-range value per equivalence class** — one below
   the minimum, one at the boundary, one above the maximum, one wrong type.
   Thirty near-identical boundary cases prove what four prove.

## `tags=refused` inverts the verdict

`tf.sh run-api` flips pass/fail for a `refused` case: a `200` on an endpoint
that should have rejected you is a **failure**, because that is the bug being
hunted. Tag every no-session and wrong-role case; an untagged one reports green
on exactly the response you were trying to catch.

## The line you may not cross

A case is `api` only if it is a **headless endpoint — nothing a person ever
sees.** If a human navigates to it and reads it, it is `page`, even when the
answer is a refusal, and even though `page` costs tokens. See the routing rule
in the skill, and `skills/test-security/SKILL.md` for why a status code cannot
tell a refusal from a leak.

Anything that writes, deletes or acts in bulk gets `tags=destructive` and
`status=skipped`.
