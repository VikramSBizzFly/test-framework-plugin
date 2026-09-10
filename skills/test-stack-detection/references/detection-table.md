# Stack detection table and output shape

## Table

| Manifest **and** runtime on PATH | stack | runner | binding |
| --- | --- | --- | --- |
| `package.json` + `node`/`bun`/`deno` | `js` | `npx playwright test` | `@playwright/test` |
| `pyproject.toml`/`requirements.txt` + `python` | `python` | `pytest` | `pytest-playwright` |
| `pom.xml`/`build.gradle` + `mvn`/`gradle` | `java` | `mvn test` | `com.microsoft.playwright` |
| `*.csproj`/`*.sln` + `dotnet` | `dotnet` | `dotnet test` | `Microsoft.Playwright.NUnit` |
| anything else, or runtime absent | `none` | — | — |

Detecting `js` does **not** mean Tier 1. Check the binding is actually present
(`node_modules/@playwright/test`, `pip show pytest-playwright`, …). Absent
binding → Tier 0, with a note.

## Output

```json
{
  "tier": 0,
  "stack": "none",
  "runner": null,
  "spec_dir": "tests/specs",
  "report": null,
  "allow_remote": false,
  "max_tokens_per_run": 200000,
  "perf_budget_ms": 3000
}
```
