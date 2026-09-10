# Java codegen — Playwright for Java + JUnit 5

Applies only once `com.microsoft.playwright` resolves from the project's own
`pom.xml`/`build.gradle` (Tier 1 detection already confirmed this — never add
the dependency yourself and never run `mvn install` to fetch it).

## Recipe verb -> Playwright call

| recipe | Playwright (Java) |
| --- | --- |
| `nav <route>` | `page.navigate("<route>");` |
| `fill <kind:Name> <value>` | `page.getByRole(AriaRole.<KIND>, new Page.GetByRoleOptions().setName("Name")).fill("<value>");` |
| `click <kind:Name>` | `page.getByRole(AriaRole.<KIND>, new Page.GetByRoleOptions().setName("Name")).click();` |
| `check <kind:Name>` | `page.getByRole(AriaRole.CHECKBOX, new Page.GetByRoleOptions().setName("Name")).check();` |
| `select <kind:Name> <value>` | `page.getByLabel("Name").selectOption("<value>");` |
| `expect url <path>` | `assertThat(page).hasURL(Pattern.compile("<path>"));` |
| `expect text <kind:Name> <text>` | `assertThat(page.getByRole(AriaRole.<KIND>, new Page.GetByRoleOptions().setName("Name"))).hasText("<text>");` |
| `expect visible <kind:Name>` | `assertThat(page.getByRole(AriaRole.<KIND>, new Page.GetByRoleOptions().setName("Name"))).isVisible();` |

`kind:Name` maps to the `AriaRole` enum constant (`button:Sign in` ->
`AriaRole.BUTTON`). Fall back to `getByLabel` for a visible label with no role
match, `getByTestId` only as a last resort.

## Storage state, never a login

`PlaywrightBase` (see `templates/java/PlaywrightBase.java`) opens the browser
context with `.setStorageStatePath(Paths.get("tests/.auth/" + role +
".json"))`. A generated test class never drives the login form.

## Naming — the hyphen problem

`INV-014` is not a legal Java identifier. Use an underscore in its place and
keep the human title in a `@DisplayName`:

```java
class InvoiceTest extends PlaywrightBase {
  @Test
  @DisplayName("INV-014 create an invoice")
  void INV_014_create_an_invoice() {
    page.navigate("/invoices/new");
    page.getByLabel("Amount").fill("100");
    page.getByRole(AriaRole.BUTTON, new Page.GetByRoleOptions().setName("Save")).click();
    assertThat(page).hasURL(Pattern.compile("/invoices/\\d+"));
  }
}
```

`JunitToCsv.java` matches `([A-Z]+)_(\d+)` against the `<testcase name>`
attribute in the Surefire/Failsafe XML and rejoins it as `<PREFIX>-<NNN>`.
Do not rely on `@DisplayName` reaching the XML — plugin configuration varies;
the method name is the one source of truth the adapter trusts.

## Grouping

One `@Test`-bearing class per feature (`InvoiceTest`, `PayrollTest`), one
method per case, extending the shared `PlaywrightBase`.

## baseURL

Read once in `PlaywrightBase` from `tests/credentials.json`'s `base_url` key
(the class includes a minimal hand-rolled reader — no JSON library is assumed
present). Never hardcode a URL in a test class.
