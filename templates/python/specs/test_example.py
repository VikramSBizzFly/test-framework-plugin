# Example only — the spec-writer agent generates one file like this per
# feature from a passing recipe. Delete it once real specs exist, or keep it
# as a locator-style reference.
#
# Rules this file demonstrates (see skills/test-codegen/references/python.md):
#   - get_by_role/get_by_label/get_by_test_id locators, never CSS or XPath
#   - storage state reused via the `role`/`context` fixtures, never a login
#   - the case id encoded in the function name (INV-014 -> INV__014, the
#     double underscore stands in for the hyphen a Python identifier can't
#     hold) and recovered by junit_to_csv.py
#   - one module per feature
import re

import pytest
from playwright.sync_api import Page, expect


@pytest.fixture
def role():
    return "admin"


def test_INV__014_create_an_invoice(page: Page):
    page.goto("/invoices/new")
    page.get_by_label("Amount").fill("100")
    page.get_by_role("button", name="Save").click()
    expect(page).to_have_url(re.compile(r"/invoices/\d+"))
