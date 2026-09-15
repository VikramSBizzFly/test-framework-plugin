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

## How a case describes its request

Five state columns, written alongside `type` and `route` in the scratch TSV:

| column | what | example |
| --- | --- | --- |
| `method` | HTTP method; **always write it**, even `GET` | `POST` |
| `body` | inline text, or `@path` relative to `tests/` | `{"name": "x"}` · `@api/bodies/ITEM-004.json` |
| `headers` | `Name: value` pairs, separated by `\|` | `X-Signature: {{hmac-sha256:webhook}}` |
| `expect_code` | the status that settles the verdict; **always write it** | `201` · `2xx` · `4xx` · `401\|403` · `refused` |
| `repeat` | send N times, judge the last response | `6` |

`refused` means 401, 403, 404, 302, 303 or 307 — never a 2xx. A JSON body gets
`Content-Type: application/json` unless `headers` sets one. Bodies longer than a
line belong in `tests/api/bodies/<id>.json`.

Placeholders are resolved when the request is sent, so no secret or session
value is ever written into the suite:

- `{{cookie:NAME}}` — a cookie from the role's session (CSRF double-submit).
- `{{secret:NAME}}` — `secrets.NAME` in `tests/credentials.json`.
- `{{env:NAME}}` — an environment variable.
- `{{hmac-sha256:NAME}}` (headers only) — hex HMAC-SHA256 of the exact body,
  keyed by `secrets.NAME`. Needs `openssl`.

## A case that cannot be judged is UNJUDGED, not FAIL

A non-GET case with no `expect_code`, a case with no `method` that gets `405`, a
missing secret or body file: `run-api` reports these as **UNJUDGED**, lists
them apart with the reason, and leaves their `status` alone. They are not
failures — but they are not coverage either, so fix them: `tf.sh set <id>
method=POST expect_code=2xx`.

## The cases worth generating

Per endpoint, deliberately, not one per field:

1. **Happy path** — valid input, `expect_code` of the documented success.
2. **No session**, when the endpoint requires auth — `who=nobody`,
   `expect_code=refused`.
3. **A required field missing** — `expect_code=4xx`.
4. **One wrong-type or out-of-range value per equivalence class** — one below
   the minimum, one at the boundary, one above the maximum, one wrong type.
   Thirty near-identical boundary cases prove what four prove.

And, where the contract has them:

- **Signed webhooks** — one correctly signed (`X-Signature:
  {{hmac-sha256:webhook}}`, `expect_code=2xx`), one signed with the wrong secret
  (`expect_code=401|403`), one unsigned.
- **Brute-force limits** (login, 2FA, password reset) — a wrong code with
  `repeat` one past the documented limit and `expect_code=429` (or `423`). Tag it
  `ends-session`: a lockout can end the session it ran under.
- **Sign-out** — `method=POST`, `expect_code=2xx`. A sign-out route, or any case
  tagged `ends-session`, runs on a throwaway login so the rest of the run keeps
  its session; that needs the role's username and password in credentials.json.

## `tags=refused` without an `expect_code`

An older case with no `expect_code` still works: `tags=refused` inverts pass/fail,
so a `200` on an endpoint that should have rejected you is a **failure**. New
cases state `expect_code` instead — it says exactly what "rejected" means.

## The line you may not cross

A case is `api` only if it is a **headless endpoint — nothing a person ever
sees.** If a human navigates to it and reads it, it is `page`, even when the
answer is a refusal, and even though `page` costs tokens. See the routing rule
in the skill, and `skills/test-security/SKILL.md` for why a status code cannot
tell a refusal from a leak.

Anything that writes, deletes or acts in bulk gets `tags=destructive` and
`status=skipped`.
