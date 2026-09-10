// Example only — the spec-writer agent generates one file like this per
// feature from a passing recipe. It is not itself run by the framework;
// delete it once real specs exist, or leave it as a locator-style reference.
//
// Rules this file demonstrates (see skills/test-codegen/references/js.md):
//   - getByRole/getByLabel/getByTestId locators, never CSS or XPath
//   - storage state reused, never a login performed in the spec
//   - the case id stamped as the first token of the test title
//   - one describe block per feature
import { test, expect } from '@playwright/test';

test.describe('invoice', () => {
  test.use({ storageState: 'tests/.auth/admin.json' });

  test('INV-014 create an invoice', async ({ page }) => {
    await page.goto('/invoices/new');
    await page.getByLabel('Amount').fill('100');
    await page.getByRole('button', { name: 'Save' }).click();
    await expect(page).toHaveURL(/\/invoices\/\d+/);
  });
});
