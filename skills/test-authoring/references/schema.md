# Test case columns and field detail

> `tf.sh` = `"$CLAUDE_PLUGIN_ROOT/scripts/tf.sh"` (not on PATH).

## Type decision table

`type` lives in `tests/.cache/state.csv`, set with `tf.sh set <id> type=...`,
and is exactly two values.

| Ask | `type` | Cost |
| --- | --- | --- |
| Does clicking Save show the new row in the table? | `page` | browser |
| Does the page render at 375px without breaking layout? | `page` | browser |
| Does opening this URL as the wrong role show a login page or a refusal? | `page` | browser |
| Does a `GET`/`POST` to `/api/...` (with a body, headers, a signature) return the right status? | `api` | free |

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

The visible store is the QA team's layout -- the **Test Cases** sheet of
`tests/testcases.xlsx`, and `tests/.cache/testcases.csv` beneath it. Query and
write these:

```
Test Case ID,Module,Test Scenario,Test Description,Preconditions,Test Case Steps,Test Data,Expected Result,Actual Result,Status
```

Every column has a one-word alias, so a TSV header or `--cols` never needs
shell quoting: `id module scenario description preconditions steps data
expected actual status`.

- **Test Case ID** (`id`) -- `AREA-NNN`, allocated with `tf.sh next-id
  <PREFIX>`. **Stable forever.** Never renumber; results, specs and bugs are
  keyed on it.
- **Module** (`module`) -- the feature this case belongs to.
- **Test Scenario** (`scenario`) -- one line naming what is being tested, as a
  heading a tester would scan: "Admin creates an invoice with a zero amount".
- **Test Description** (`description`) -- why the case exists, or anything a
  person wants to remember. Optional. A re-merge never overwrites it.
- **Preconditions** (`preconditions`) -- the state before step one, in words:
  "Not logged in", "Logged in as admin", "Logged in as admin; at least one
  invoice exists". **The login part is read by the engine**: "Not logged in"
  runs without a session and "Logged in as <role>" runs as that role -- unless
  a `role` column says otherwise.
- **Test Case Steps** (`steps`) -- plain English, no code, no selectors: "Open
  the invoice page, click New, fill Amount with 0, click Save." A non-technical
  reader should be able to follow it by hand. Multiple steps separate with `|`
  or with numbered sentences, never a line break.
- **Test Data** (`data`) -- the specific inputs, when they matter: "Amount: 0",
  "email: not-an-email". Empty for most cases.
- **Expected Result** (`expected`) -- one observable outcome, in the words a
  user would use: "An error says the amount must be greater than zero." Not a
  paragraph, not an assertion in code.
- **Actual Result** (`actual`) -- **leave empty.** The runner writes what it saw:
  `HTTP 401`, or one sentence for a page. A re-merge never overwrites it.
- **Status** (`status`) -- leave empty or `Not Run`; the runner owns it. Values
  are `Not Run` / `Pass` / `Fail` / `Blocked` / `Flaky` / `Skipped`. `Blocked`
  means the run could not judge it (the request never completed); `Flaky` is set
  by triage after three verdict flips with no source change (see the
  **test-triage** skill) and is excluded from the gating verdict but never
  dropped or hidden.

There is no priority column. What a bare `/test-run` falls back to is the
`smoke` tag -- give it to the cases that must always work.

Bookkeeping file, `tests/.cache/state.csv` (never hand-edit; `tf.sh set`
routes non-visible fields here automatically):

```
id,type,route,tags,source_files,spec_file,last_run,last_result,pass_streak,flake_count,viewport,method,body,headers,expect_code,repeat,role
```

- **`role`** -- the session a case runs with: `nobody`, or a key from
  `credentials.json` (`admin`, `user`, ...). Set it explicitly in the authoring
  TSV when Preconditions would be ambiguous; otherwise merge derives it from
  Preconditions. The alias `who` resolves here.
- `method`, `body`, `headers`, `expect_code` and `repeat` describe the request an
  `api` case sends; see `api-contracts.md`.

`route` groups cases for browser page-model reuse, so get it right -- a wrong
route means a wasted page model. `tags` is comma-separated; `destructive`,
`smoke`, `refused` and `ends-session` are load-bearing. `source_files` is
semicolon-separated, from discovery, and powers `--changed`.

## An example row

```
id	module	scenario	preconditions	steps	data	expected	type	route	tags
INV-004	invoice	Admin saves an invoice with a zero amount	Logged in as admin	Open /invoices/new | fill Amount | click Save	Amount: 0	An error says the amount must be greater than zero	page	/invoices/new	
```

## What a feature needs

For each feature, cover: the happy path (tag it `smoke` if it must always work) · one
validation or boundary case per constrained field · role-negative access
(usually generated) · the empty state · one error state (bad input, failed
request).

## Equivalence-class sampling

Thirty near-identical boundary cases prove what four prove. Per field emit:
one below the minimum, one at the boundary, one above the maximum, one wrong
type — not one per value. Expand exhaustively only under `--exhaustive`.

## Wording a case for a non-technical reader

**Test Case Steps** reads like an instruction you'd hand a new hire, not a
script: name the page and the actions in order, using the labels visible on
screen ("click New", "fill Amount") rather than selectors or field names from
the code. Put who is logged in in **Preconditions**, not in the steps.
**Expected Result** names the single outcome a person watching the screen would
notice — a message, a redirect, a row appearing — not an internal state change
nothing on screen reflects.
