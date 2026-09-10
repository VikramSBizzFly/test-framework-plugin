# testcases.csv schema and field detail

> `tf.sh` = `"$CLAUDE_PLUGIN_ROOT/scripts/tf.sh"` (not on PATH).

## Type decision table

`type` lives in `tests/.cache/state.csv`, set with `tf.sh set <id> type=...`,
and is exactly two values.

| Ask | `type` | Cost |
| --- | --- | --- |
| Does clicking Save show the new row in the table? | `page` | browser |
| Does the page render at 375px without breaking layout? | `page` | browser |
| Does opening this URL as the wrong role show a login page or a refusal? | `page` | browser |
| Does a bare `GET`/`POST` to `/api/...` return the right status/shape? | `api` | free |

The old `ui`/`rbac`/`auth`/`visual`/`a11y`/`perf` type values are gone.
Everything a person can navigate to and look at — including a permission
check — is `page`, because only a rendered page can distinguish a real
refusal (a login redirect, a visible "Access denied") from a page that
happens to return HTTP 200 with the wrong content, and because a
client-side guard (a redirect written in JS) never touches the network at
all — curl cannot see it. `api` is for genuinely headless endpoints only:
no HTML, no browser involved, a status code and a JSON shape settle it
completely.

Writing a real permission check as `api` is the single most expensive
mistake you can make here — not in tokens, but in false confidence: it will
report PASS on an app that is actually showing everyone an admin page.

The RBAC and auth sweeps are generated for you — run `tf.sh rbac
tests/.cache/routes.txt tests/.cache/privileged.txt` rather than writing
those rows by hand. It already assigns `page` to every route it walks and
`api` only to routes it finds under `/api/`.

## Columns

Human file, `tests/testcases.csv` (query/write these):

```
id,area,who,what to do,what should happen,priority,status,notes
```

- **`id`** — `AREA-NNN`, allocated with `tf.sh next-id <PREFIX>`. **Stable
  forever.** Never renumber; results and specs are keyed on it.
- **`area`** — the feature this case belongs to. Alias `feature`.
- **`who`** — `nobody` for anonymous, `normal user` for a default account,
  `admin` or the role's own name for anything privileged. Alias `role`.
- **`what to do`** — plain English, no code, no selectors: "Log in as normal
  user, open the invoice page, click New, fill Amount with 0, click Save."
  A non-technical reader should be able to follow it by hand. Aliases
  `todo`/`do`/`steps`.
- **`what should happen`** — one observable outcome, in the words a user
  would use: "Should show an error saying the amount must be greater than
  zero." Not a paragraph, not an assertion in code. Aliases
  `expect`/`should`/`expected`.
- **`priority`** — `high` (must work, bare `/test-run` only executes these)
  · `medium` (core) · `low` (edge case).
- **`status`** — leave `new`; the runner owns it from then on. Values are
  `new` / `passing` / `failing` / `skipped`.
- **`notes`** — anything a human wants to remember. Never touched by a run
  unless someone hand-edits it.

Bookkeeping file, `tests/.cache/state.csv` (never hand-edit; `tf.sh set`
routes non-human fields here automatically):

```
id,type,route,tags,source_files,spec_file,last_run,last_result,pass_streak,flake_count,viewport
```

`route` groups cases for browser page-model reuse, so get it right — a wrong
route means a wasted page model. `tags` is comma-separated; `destructive`
and `smoke` are load-bearing. `source_files` is semicolon-separated, from
discovery, and powers `--changed`.

## What a feature needs

For each feature, cover: the happy path (high/medium priority) · one
validation or boundary case per constrained field · role-negative access
(usually generated) · the empty state · one error state (bad input, failed
request).

## Equivalence-class sampling

Thirty near-identical boundary cases prove what four prove. Per field emit:
one below the minimum, one at the boundary, one above the maximum, one wrong
type — not one per value. Expand exhaustively only under `--exhaustive`.

## Wording a case for a non-technical reader

`what to do` reads like an instruction you'd hand a new hire, not a script:
name the role, the page, and the actions in order, using the labels visible
on screen ("click New", "fill Amount") rather than selectors or field
names from the code. `what should happen` names the single outcome a person
watching the screen would notice — a message, a redirect, a row appearing —
not an internal state change nothing on screen reflects.
