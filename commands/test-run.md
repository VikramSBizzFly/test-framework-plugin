---
description: Find pages, write the tests, and run them in a browser
---

> `tf.sh` = `"$CLAUDE_PLUGIN_ROOT/scripts/tf.sh"` (not on PATH).

Run the tests. Arguments: `$ARGUMENTS`

Flags: `--changed` `--all` `--feature <area>` `--only-failing` `--headed`
`--fresh` `--allow-destructive`.

**Bare `/test-run` means `--changed`**, falling back to high-priority cases when
nothing has changed. A full browser run takes minutes, so the whole suite is
always an explicit `--all`.

## 1. Check the app is up

`tf.sh preflight`. If it is down, stop and say so. A dead app should cost one
request, not a suite of failures.

Then confirm each role still has a session. Sessions expire; if one has, run
`tf.sh login <role>` again now rather than discovering it forty cases later.

## 2. Write or refresh the tests

`tf.sh cache-check <src>` first. **Exit 0 means skip this whole step** — the
source has not changed, the existing cases are current, and regeneration is
free. Only continue on exit 1, or with `--fresh`.

Otherwise load the **test-discovery** skill, then **test-authoring**:

```sh
tf.sh routes <src> > tests/.cache/routes.txt
# then: group pages into areas, and list which pages need a login
tf.sh rbac tests/.cache/routes.txt tests/.cache/privileged.txt > /tmp/new.csv
tf.sh merge /tmp/new.csv
tf.sh prune --apply
```

`merge` never overwrites a `status` or a `notes` the user wrote, so this is
always safe to re-run.

## 3. Check the cost before spending it

`tf.sh cost --check`. Exit 1 means the projection exceeds `max_tokens_per_run`
in `tests/framework.json` — stop, show the projection, and suggest narrowing
(`--changed`, `--feature`) rather than starting a run they capped.

## 4. Run them, cheapest first

1. **`tf.sh run-api`** — `type=api` cases, over curl. Free. Always run these
   first; they are fast and a broken build shows up before a browser opens.
2. **Promoted specs** — any case with a `spec_file`, run by the project's own
   test command. Also free.
3. **Browser** — everything else. Load the **test-execution** skill and hand
   route groups to the `test-runner` agent. `--headed` shows the browser.
4. **Failures only** get further attention, via **test-triage**.

## 5. Print the panel

`tf.sh summary` prints at the end of the run. **Print it verbatim and add
nothing** — no restating counts, no re-listing failures, no congratulating.

Say something only if the panel cannot: the app would not start, a login
failed, or you deliberately ran a narrow selection.
