---
description: Show the last test result again
---

> `tf.sh` = `"$CLAUDE_PLUGIN_ROOT/scripts/tf.sh"` (not on PATH).

Show the last result. Arguments: `$ARGUMENTS`
(`--coverage` for gaps · `--bug <id>` for a bug report · `--publish` for a
shareable page).

Run `tf.sh summary` and **print its output verbatim. Add nothing.** It already
renders the verdict, what regressed, what got fixed and what to do next.
Re-describing it costs more than the run did.

Load the **test-reporting** skill for anything beyond that.

**`--coverage`** → `tf.sh cover tests/.cache/routes.txt`. Group untested pages
by area and say which look risky — anything behind a login, anything that takes
input, anything touching money or personal data. Do not just list everything.

**`--bug <id>`** → build a bug report for that case: what to do, what should
happen, what actually happened, the evidence in `tests/evidence/<id>/`, and the
likely source file from `source_files`. Offer `gh issue create`.
**Never put a password in a bug report.**

**`--publish`** → `tf.sh render`, then publish it as an Artifact — after
checking no credential appears anywhere in the HTML.
