---
name: test-stack-detection
description: Detect a target project's language, test runner and framework tier, and write tests/framework.json. Use during /test-setup, or whenever you need to know which execution tier this project is on.
---

# Stack detection

> `tf.sh` = `"$CLAUDE_PLUGIN_ROOT/scripts/tf.sh"` (not on PATH).

Detect **once**, into `tests/framework.json`. Every other command reads that
file rather than re-detecting. Delegate the detection itself to the
`stack-detector` agent; it returns six lines and writes the file.

## Two rules

1. **Verify, never infer.** A `package.json` proves the project is JS; it does
   not prove Node is installed. Probe for the runtime:
   `command -v node`, `command -v python`, `command -v mvn`, `command -v dotnet`.
   Then probe the Playwright **binding** itself (`node_modules/@playwright/test`,
   `pip show pytest-playwright`, the dependency in `pom.xml`/`*.csproj`). A
   manifest without its runtime — or a runtime without its binding — is
   **Tier 0**.
2. **Never install anything.** Not npm, not pip, not a Playwright browser
   binary. If a stack is present but its Playwright binding is missing, say what
   the user *could* install to reach Tier 1, then proceed at Tier 0. The
   framework works fine there.

Full manifest/runtime/runner table and the exact `framework.json` shape are in
`references/detection-table.md` — read it before writing the file.

## Tiers

- **Tier 0** — no project dependencies at all. Cases run via curl (`tf.sh
  run-api`) and, for browser cases, replayed recipes through the Playwright
  MCP. This is the default and it is fully supported, not a degraded mode.
- **Tier 1** — the stack's Playwright binding is installed, so passing browser
  cases are promoted to native specs and re-run by the project's own runner.
- **Tier 2** — Tier 1 and the runner can emit JUnit XML, so results convert to
  CSV without model involvement.

## Production guard and reporting

`allow_remote` stays `false`. `tf.sh` refuses any non-local `base_url` without
it, and that refusal is a feature. Only set it when the user confirms the
target is a disposable test environment.

Report the tier and *why* — "no `node` on PATH, so Tier 0; install Node and
`@playwright/test` to promote passing cases to native specs" is useful. "Tier 0"
alone is not.
