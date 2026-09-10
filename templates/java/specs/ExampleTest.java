// Example only — the spec-writer agent generates one class like this per
// feature from a passing recipe. Delete it once real specs exist, or keep it
// as a locator-style reference.
//
// Rules this file demonstrates (see skills/test-codegen/references/java.md):
//   - getByRole/getByLabel/getByTestId locators, never CSS or XPath
//   - storage state reused via PlaywrightBase, never a login in the test
//   - the case id encoded in the method name (INV-014 -> INV_014, the
//     underscore stands in for the hyphen a Java identifier can't hold),
//     with the human title kept in @DisplayName for readability only
//   - one class per feature
package tests;

import com.microsoft.playwright.options.AriaRole;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.regex.Pattern;

import static com.microsoft.playwright.assertions.PlaywrightAssertions.assertThat;

class InvoiceTest extends PlaywrightBase {

    @Test
    @DisplayName("INV-014 create an invoice")
    void INV_014_create_an_invoice() {
        page.navigate("/invoices/new");
        page.getByLabel("Amount").fill("100");
        role(AriaRole.BUTTON, "Save").click();
        assertThat(page).hasURL(Pattern.compile("/invoices/\\d+"));
    }
}
