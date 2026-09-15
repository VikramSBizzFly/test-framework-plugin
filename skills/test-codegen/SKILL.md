---
name: test-codegen
description: Convert a passing recipe into a native spec file, in the target project's own language. Use only at Tier 1/2, via the spec-writer agent, once a browser case has run clean through the Playwright MCP. Never used at Tier 0.
---

# Codegen

> `tf.sh` = `"$CLAUDE_PLUGIN_ROOT/scripts/tf.sh"` (not on PATH).

A recipe (`tests/.cache/recipes/<id>.rcp`) is the line-oriented action list
compiled from one passing browser case: `nav <route>`, `fill <kind:Name>
<value>`, `click <kind:Name>`, `check <kind:Name>`, `select <kind:Name>
<value>`, `expect url <path>`, `expect text <kind:Name> <text>`, `expect
visible <kind:Name>`. Codegen turns one recipe into one native test, in the
stack `tests/framework.json` already detected. **Never generate in a language
the project doesn't use** — that is the entire reason this is Tier 1/2 only.

## Read the framework first

`tests/framework.json.stack` picks exactly one reference below. Load only
that one — a Python project must never see the Java rules, and vice versa.

| stack | reference |
| --- | --- |
| `js` | `references/js.md` |
| `python` | `references/python.md` |
| `java` | `references/java.md` |
| `dotnet` | `references/dotnet.md` |
| `none` | **stop.** Tier 0 has no native runner to write for. |

## Universal rules, every stack

1. **Locators**: role/label/test-id first — `getByRole`/`get_by_role`,
   `getByLabel`, `getByTestId`, or that language's equivalent. Never CSS or
   XPath; that is what makes self-healing possible later.
2. **Auth**: load the saved storage state at `tests/.auth/<role>.json`. A
   generated spec never re-performs a login and never contains a credential —
   those live only in `tests/credentials.json`. See the **test-auth** skill.
3. **Naming**: stamp the source case ID into the test name so results map
   back to the CSV and the JUnit adapter can recover the id.
4. **Grouping**: one suite/describe/class per feature, matching the case's
   `feature` column.
5. **baseURL**: read once from `tests/credentials.json`, never hardcoded in
   a spec.

## Output

Write under `tests/framework.json.spec_dir`, one file per feature, and
`tf.sh set <id> status=Pass spec_file=<path>` for every case promoted.
Codegen reads recipes; it never edits a case's `steps`/`expected` columns.
