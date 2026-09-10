# .NET codegen — Playwright + NUnit

Applies only once `Microsoft.Playwright.NUnit` resolves from the project's own
`.csproj` (Tier 1 detection already confirmed this — never `dotnet add
package` it yourself).

## Recipe verb -> Playwright call

| recipe | Playwright (C#) |
| --- | --- |
| `nav <route>` | `await Page.GotoAsync("<route>");` |
| `fill <kind:Name> <value>` | `await Page.GetByRole(AriaRole.<Kind>, new() { Name = "Name" }).FillAsync("<value>");` |
| `click <kind:Name>` | `await Page.GetByRole(AriaRole.<Kind>, new() { Name = "Name" }).ClickAsync();` |
| `check <kind:Name>` | `await Page.GetByRole(AriaRole.Checkbox, new() { Name = "Name" }).CheckAsync();` |
| `select <kind:Name> <value>` | `await Page.GetByLabel("Name").SelectOptionAsync("<value>");` |
| `expect url <path>` | `await Expect(Page).ToHaveURLAsync(new Regex("<path>"));` |
| `expect text <kind:Name> <text>` | `await Expect(Page.GetByRole(AriaRole.<Kind>, new() { Name = "Name" })).ToHaveTextAsync("<text>");` |
| `expect visible <kind:Name>` | `await Expect(Page.GetByRole(AriaRole.<Kind>, new() { Name = "Name" })).ToBeVisibleAsync();` |

`kind:Name` maps to the `AriaRole` enum member (`button:Sign in` ->
`AriaRole.Button`). Fall back to `GetByLabel` for a visible label with no role
match, `GetByTestId` only as a last resort.

## Storage state, never a login

`PlaywrightBase` (see `templates/dotnet/PlaywrightBase.cs`) creates the
browser context with `StorageStatePath = $"tests/.auth/{role}.json"`. A
generated test class never drives the login form.

## Naming — the hyphen problem

`INV-014` is not a legal C# identifier. Use an underscore in its place and
keep the human title as the NUnit `[Test]` description via a comment or
`TestContext` — the identifier is what the adapter trusts:

```csharp
[TestFixture]
public class InvoiceTest : PlaywrightBase
{
    [Test]
    public async Task INV_014_create_an_invoice()
    {
        await Page.GotoAsync("/invoices/new");
        await Page.GetByLabel("Amount").FillAsync("100");
        await Page.GetByRole(AriaRole.Button, new() { Name = "Save" }).ClickAsync();
        await Expect(Page).ToHaveURLAsync(new Regex(@"/invoices/\d+"));
    }
}
```

`JunitToCsv.cs` matches `([A-Z]+)_(\d+)` against the `<test-case name>`
attribute in the NUnit/`dotnet test` JUnit-style XML and rejoins it as
`<PREFIX>-<NNN>`.

## Grouping

One `[TestFixture]` per feature (`InvoiceTest`, `PayrollTest`), one `[Test]`
method per case, deriving from the shared `PlaywrightBase`.

## baseURL

Read once in `PlaywrightBase` from `tests/credentials.json`'s `base_url` key
using `System.Text.Json` (part of the BCL, not an added dependency). Never
hardcode a URL in a test class.
