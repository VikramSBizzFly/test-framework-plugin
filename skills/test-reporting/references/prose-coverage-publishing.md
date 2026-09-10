# Writing prose, coverage, and publishing detail

> `tf.sh` = `"$CLAUDE_PLUGIN_ROOT/scripts/tf.sh"` (not on PATH).

## When you do write prose

Only when the user asks a question the panel doesn't answer — "why did this
break?", "what changed?". Then: lead with the verdict, then what changed, then
what needs a human.

A regression outranks a pre-existing failure. Within regressions, order by
blast radius: a permission case (`who=nobody` or a lower role reaching a
route it shouldn't) means a real user can reach something they should not —
that goes first, always, above any broken button.

Never paste the results CSV. Never list passing cases. Never restate a full
stack trace — point at `tests/evidence/<id>/`.

Call out a case whose `flake_count` just went up separately, from the panel's
warning, not the failure list. A flip is noise, not signal, and mixing it in
trains the user to ignore the list.

## Publishing

`/test-report --publish` renders `tf.sh render` output and publishes it as an
Artifact. Before publishing, confirm no credential value appears anywhere in
the HTML — results carry roles and routes, never usernames or passwords. If one
appears, that is a bug in whatever wrote it; fix the writer, do not just scrub
the report.

## Coverage

```sh
tf.sh cover tests/.cache/routes.txt
```

Emits `uncovered <route>` and `thin <route> <n>`. Report uncovered routes
grouped by area, and say which look risky (anything privileged or accepting
input) rather than listing all of them flatly.

## Redaction detail

Redact on write, not on display. Anything reaching `results/`, `evidence/`, a
bug report or an Artifact must already be free of credential values. Roles,
routes, status codes and timings are all safe; usernames, passwords, tokens and
cookie values are not.
