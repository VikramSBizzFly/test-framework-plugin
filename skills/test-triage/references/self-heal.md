# Self-heal procedure detail

## Locator failure vs assertion failure — self-heal only the former

A **locator** failure (element not found, selector timeout) means the test
can't find something the page might still have, under a different shape. An
**assertion** failure (found the element, value is wrong) means the app did
something different than expected — that is never self-healed.

Self-heal procedure, locator failures only:

1. Take a fresh snapshot of the page (accessibility tree, not a screenshot).
2. Re-derive the locator from that snapshot — same role/name/text intent as
   before, new selector.
3. Patch the recipe or spec file, re-run **once**.
4. **Always report the patch** — old locator, new locator, spec file changed.
   Never a silent pass. A silently-patched test is a test nobody can trust.

**Decline to self-heal** if the fresh snapshot shows the *behaviour* changed —
the control is gone, disabled, or the flow now requires an extra step. That is
an app bug (or a stale test, if intended) wearing a locator failure's clothes.
When in doubt, decline and report; a wrongly-healed test hides a regression
forever.
