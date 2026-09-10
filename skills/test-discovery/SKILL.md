---
name: test-discovery
description: Map an unknown web app's routes, forms, auth guards and validation rules so test cases can be generated. Use during /test-run, or when you need the route list, the privileged-route list, or the discovery cache protocol.
---

# Discovery

> `tf.sh` = `"$CLAUDE_PLUGIN_ROOT/scripts/tf.sh"` (not on PATH).

Most of this is mechanical. **Do not read source files to answer a question
a glob can answer.**

## Step 1 — deterministic extraction (free)

```sh
tf.sh routes  <src> > tests/.cache/routes.txt   # route list, all frameworks
tf.sh forms   <src>                             # files containing forms
tf.sh schemas <src>                             # validation constraints
tf.sh hash    <src> > tests/.cache/hash         # cache key
```

`tf.sh routes` covers Next.js, React/Vue Router, Django, Flask/FastAPI, Rails,
Spring, ASP.NET and Express, and doesn't classify what it finds — skim and
delete non-routes rather than re-deriving the list yourself.

## Step 2 — cache check

`tf.sh cache-check <src>` — **exit 0 means stop.** Source unchanged, so
`tests/.cache/` is current and regeneration is free. Exit 1 means cold or
stale: rebuild only the affected areas. It does the hash comparison itself;
do not eyeball it.

## Step 3 — the judgements only you can make (one pass over the route list, not per-route work)

**a. Classify each route `page` or `api`.** `/api/`-style, JSON/status only
→ `api`. Everything a person navigates to and looks at, including a page
that only ever refuses access → `page`. `tf.sh rbac` already applies this.

**b. Group routes into features and name them.** `/invoices`, `/invoices/1`,
`/invoices/new` are one feature, `invoice`. Assign a stable ID prefix and
write `feature PREFIX routes... src_dir` to `tests/.cache/featuremap.txt`
(format: `references/live-crawl-and-delegation.md`).

**c. Identify privileged routes.** Read the auth guards (`middleware.ts`,
`@PreAuthorize`, `[Authorize]`, `before_action`) and list routes requiring
elevated roles, one per line, to `tests/.cache/privileged.txt`. Then
`tf.sh rbac tests/.cache/routes.txt tests/.cache/privileged.txt > /tmp/rbac.csv
&& tf.sh merge /tmp/rbac.csv`. Without that list `tf.sh rbac` falls back to a
name heuristic and says so — this cheap pass makes hundreds of free
permission cases *correct*, not guessed.

## Step 4, delegation, and never

Live-crawl only when static discovery clearly missed routes; run
`test-explorer` agents in parallel only over the static pass. Procedure and
the crawl/run serialization rule: `references/live-crawl-and-delegation.md`.

Never: read whole source files into the main thread, enumerate routes by hand,
re-explore an unchanged repo, or return snapshots/DOM to the caller.
