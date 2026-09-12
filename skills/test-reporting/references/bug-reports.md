# Turning a failure into a bug report

> `tf.sh` = `"$CLAUDE_PLUGIN_ROOT/scripts/tf.sh"` (not on PATH).

`/test-report --bug <id>` delegates to the `bug-reporter` agent, so the evidence
files stay out of the main conversation. Triage first: a report whose verdict is
`stale-test` or `environment` should never be filed as an app bug.

## Gather

```sh
tf.sh select --id <id> --cols id,area,who,route,todo,expect,status,source_files,last_result
```

Then read `tests/evidence/<id>/` — the judging snapshot, the screenshot, the
console and network capture — and the triage verdict if one exists. Use
`source_files` to name the likely file, and confirm it with grep rather than
guessing; cite `path:line`.

## The shape

```
<id> — <one-line title: the behaviour, not the test>

What to do:             <the case's steps, plain English>
What should happen:     <the expected>
What actually happened: <what the evidence shows>
Who:                    <role>          Route: <route>
Verdict:                <app-bug|stale-test|environment|flake>
Evidence:               tests/evidence/<id>/...
Likely source:          <path:line>
```

Title the behaviour, not the case: "payroll renders for a logged-out visitor",
not "RBAC-USER-002 failed". The first is a bug someone can act on; the second is
a row id.

Then offer a `gh issue create` command with that body. **Offer it; do not run
it.** Filing into someone's tracker is their call, not yours.

## Redaction

Everything in `## Redaction detail` of `prose-coverage-publishing.md` applies
here, and a bug report is the destination most likely to be pasted somewhere
public. Roles, routes, status codes and timings are safe; usernames, passwords,
tokens, cookie values and the records a leak exposed are not.

If the evidence cannot be quoted without leaking, describe it and cite the
path — the path is always the safer answer. For a security finding, say *that*
protected content rendered and which field proved it, never the value.
