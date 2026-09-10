# Python codegen — pytest-playwright

Applies only once `pytest-playwright` is confirmed installed (`pip show
pytest-playwright` during Tier 1 detection — never `pip install` it here).

## Recipe verb -> Playwright call

| recipe | Playwright (sync API) |
| --- | --- |
| `nav <route>` | `page.goto("<route>")` |
| `fill <kind:Name> <value>` | `page.get_by_role("<kind>", name="Name").fill("<value>")` |
| `click <kind:Name>` | `page.get_by_role("<kind>", name="Name").click()` |
| `check <kind:Name>` | `page.get_by_role("checkbox", name="Name").check()` |
| `select <kind:Name> <value>` | `page.get_by_label("Name").select_option("<value>")` |
| `expect url <path>` | `expect(page).to_have_url(re.compile("<path>"))` |
| `expect text <kind:Name> <text>` | `expect(page.get_by_role("<kind>", name="Name")).to_have_text("<text>")` |
| `expect visible <kind:Name>` | `expect(page.get_by_role("<kind>", name="Name")).to_be_visible()` |

`kind:Name` maps straight to the ARIA role; fall back to `get_by_label` when
there's a visible label but no role match, and `get_by_test_id` only as a
last resort.

## Storage state, never a login

The `context` fixture in `templates/python/conftest.py` reads
`storage_state=f"tests/.auth/{role}.json"` — override the `role` fixture per
test module, never call the login form from inside a spec.

## Naming — the hyphen problem

A case id like `INV-014` is not a legal Python identifier. Encode it with a
double underscore in place of the hyphen and keep the human title after a
single underscore:

```python
def test_INV__014_create_an_invoice(page):
    page.goto("/invoices/new")
    page.get_by_label("Amount").fill("100")
    page.get_by_role("button", name="Save").click()
    expect(page).to_have_url(re.compile(r"/invoices/\d+"))
```

`junit_to_csv.py` reverses this: it matches `test_([A-Z]+)__(\d+)` against the
pytest node id and rejoins it as `<PREFIX>-<NNN>`. Never invent a different
separator — the adapter only knows this one convention.

## Grouping

One module per feature (`tests/specs/test_invoice.py`), not one class per
case. `pytest.mark.describe`-style grouping is unnecessary; the filename is
the suite.

## baseURL

Read once in `conftest.py` from `tests/credentials.json["base_url"]` and
passed via the `base_url` fixture. Never hardcode a URL in a spec file.
