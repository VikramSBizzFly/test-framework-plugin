---
name: test-authoring
description: Write test cases into tests/testcases.csv for this framework. Use when generating, adding, editing, deduplicating or prioritising test cases, or when you need the CSV schema, the HTTP-first rule, or the stable-ID convention.
---

# Authoring test cases

> `tf.sh` = `"$CLAUDE_PLUGIN_ROOT/scripts/tf.sh"` (not on PATH).

Delegate authoring to the `case-author` agent, one call per feature, and API
cases to `api-case-author`. Both write to a scratch CSV and `tf.sh merge`.

Cases come from three inputs, not one: the **page model** (every interactive
element and its constraints), the **flows** in `tests/.cache/flows.txt` (the
end-to-end journey and each of its real failure branches — see the
**test-flows** skill), and the free `tf.sh rbac` sweep.

`tests/testcases.xlsx` is the store a person opens: the **Test Cases** sheet
carries the eight plain-English columns, the **Flows** sheet the journeys, the
**Results** sheet the last run. The engine reads a CSV copy in
`tests/.cache/`, because awk cannot read a workbook; `tf.sh xlsx` keeps the two
in step, and `tf.sh xlsx --import` pulls hand edits back in. Bookkeeping lives
in `tests/.cache/state.csv`, never hand-edited. `tf.sh select` joins both transparently — write and query the
human file, forget the other exists. **Never `cat` either file.** Query them:

```sh
tf.sh select --status new --priority high --cols id,route,type --format plain
tf.sh stats
tf.sh next-id AUTH
```

## The routing rule (page vs api)

**A case is `api` only if it is a headless endpoint — nothing a person ever
sees.** Everything a user can see, including a permission check, is `page`.
`page` opens a real browser; `api` runs as curl, zero tokens.

Why: a permission refusal is often a page served with HTTP 200 and the text
"Access denied" — a status code misses it, and a client-side guard doesn't
exist for curl to hit. Only a rendered page proves a refusal actually
refuses. When in doubt: *is this a `/api/*` call, or does it render?* Table:
`references/schema.md`. RBAC/auth sweeps are generated — run `tf.sh rbac`.
Why a status code cannot decide this, and the probes the sweep cannot express:
the **test-security** skill. Generating `api` cases from an OpenAPI/Swagger
contract: `references/api-contracts.md`.

## Schema

```
id,area,who,what to do,what should happen,priority,status,notes
```

Plain English, not steps a script would understand. `who` is `nobody` /
`normal user` / `admin` (or whatever the role is called). Aliases avoid
CSV-quoting a multi-word column: `todo`/`do`/`steps`→"what to do",
`expect`/`should`/`expected`→"what should happen", `role`→`who`,
`feature`→`area`. `id` is stable forever — never renumber. `status` starts
`new`; the runner owns it after, rewriting it only when a verdict changed,
so hand edits and git stay clean. Field detail, feature coverage, and
equivalence-class sampling: `references/schema.md`.

Write new cases to a scratch CSV with the same 8-column header, then
`tf.sh merge <file>`. Merge keeps existing IDs and never overwrites a
`status` or `notes` a human already set — regeneration is always safe.

## Destructive cases, and before finishing

Anything that deletes, cancels, deactivates, or acts in bulk gets
`tags=destructive` (set with `tf.sh set`) and `status=skipped`. Runs only
under `--allow-destructive` — write them, just don't arm them.

`tf.sh prune` surfaces definition-identical duplicates, `tf.sh stats`
confirms the mix. Don't force a permission or content check into `api` just
because it's free — a false pass there costs more than the tokens it saved.
