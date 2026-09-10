---
description: Set this project up for testing and log in
---

> `tf.sh` = `"$CLAUDE_PLUGIN_ROOT/scripts/tf.sh"` (not on PATH).

Set up testing here. Arguments: `$ARGUMENTS` (`--tier 0` forces browser-only).

**1. Work out what this project is.** Load the **test-stack-detection** skill.
Detect the stack, and *verify the runtime is actually on PATH* — a
`package.json` does not prove Node is installed. **Never install anything.**

**2. Scaffold**, without overwriting anything that exists:
- `tf.sh init-csv` — creates `tests/`, `tests/testcases.csv`, and the
  supporting folders in one go
- `tests/framework.json` from `templates/shared/framework.example.json`
- `tests/credentials.json` from the example — **only if absent**. It holds real
  logins; never overwrite it.
- append to `.gitignore`: `tests/credentials.json`, `tests/.auth/`,
  `tests/.cache/`, `tests/evidence/`, `tests/results/`
- copy `templates/<stack>/` **only if tier >= 1**

**3. Migrate an older suite.** If `tests/testcases.csv` already exists in the
old 20-column format, run `tf.sh migrate`. It keeps every id and all history.

**4. Log in.** For each role in `credentials.json`, `tf.sh login <role>`.

If that fails the site uses a JavaScript or SSO login, so do it in a real
browser instead: open the login page, fill the credentials, and **stop and ask
the user to finish it by hand** if there is 2FA or a CAPTCHA — never try to
solve or bypass those. Then save the storage state to `tests/.auth/<role>.json`.

**Never print a password or cookie into the transcript.**

Finish by telling the user the tier, why, and to run `/test-run`.
