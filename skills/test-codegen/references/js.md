# JS/TS codegen — Playwright Test

Applies only once `@playwright/test` is confirmed in `node_modules` (Tier 1
detection already did this — never `npm install` it here).

## Recipe verb -> Playwright call

| recipe | Playwright |
| --- | --- |
| `nav <route>` | `await page.goto('<route>');` |
| `fill <kind:Name> <value>` | `await page.getByRole('<kind>', { name: 'Name' }).fill('<value>');` |
| `click <kind:Name>` | `await page.getByRole('<kind>', { name: 'Name' }).click();` |
| `check <kind:Name>` | `await page.getByRole('checkbox', { name: 'Name' }).check();` |
| `select <kind:Name> <value>` | `await page.getByLabel('Name').selectOption('<value>');` |
| `expect url <path>` | `await expect(page).toHaveURL(/<path>/);` |
| `expect text <kind:Name> <text>` | `await expect(page.getByRole('<kind>', { name: 'Name' })).toHaveText('<text>');` |
| `expect visible <kind:Name>` | `await expect(page.getByRole('<kind>', { name: 'Name' })).toBeVisible();` |

`kind:Name` is the recipe's own locator token (`button:Sign in`,
`textbox:Email`). Map `kind` straight to the matching ARIA role. If the
element has a visible `<label>` but no accessible role match, fall back to
`getByLabel`; use `getByTestId` only when neither role nor label exists.

## Storage state, never a login

```ts
test.use({ storageState: 'tests/.auth/admin.json' });
```

One `test.use` per role, at the top of the describe block. A generated spec
must never call `.fill()` on a password field or POST to the login route —
that is a login, and it is forbidden here; the saved state already proves it
happened once.

## Skeleton

```ts
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
```

The case ID is the literal first token of the test title — a JS/TS string can
hold the hyphen directly, so `junit-to-csv.mjs` recovers it with a plain
`/^([A-Z]+-\d+)/` match against the JUnit `<testcase name>`.

## baseURL

Set once in `playwright.config.ts`, read from `tests/credentials.json` at
config-load time (see `templates/js/playwright.config.ts`). Never hardcode a
URL inside a spec file.
