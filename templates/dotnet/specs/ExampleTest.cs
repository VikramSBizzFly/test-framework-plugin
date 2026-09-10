// Example only — the spec-writer agent generates one fixture like this per
// feature from a passing recipe. Delete it once real specs exist, or keep it
// as a locator-style reference.
//
// Rules this file demonstrates (see skills/test-codegen/references/dotnet.md):
//   - GetByRole/GetByLabel/GetByTestId locators, never CSS or XPath
//   - storage state reused via PlaywrightBase, never a login in the test
//   - the case id encoded in the method name (INV-014 -> INV_014, the
//     underscore stands in for the hyphen a C# identifier can't hold)
//   - one fixture per feature
using System.Text.RegularExpressions;
using Microsoft.Playwright;
using NUnit.Framework;

namespace Tests;

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
