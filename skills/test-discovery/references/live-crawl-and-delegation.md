# Live crawl and delegation detail

## Featuremap line format

```
invoice   INV   /invoices /invoices/1 /invoices/new   src/app/invoices
payroll   PAY   /payroll /payroll/run                 src/app/payroll
```

## Step 4 — live crawl, only if needed

Only when static discovery clearly missed something — routes built at runtime, a
SPA with no route table. This is expensive; prefer to be wrong on the side of
fewer routes and let `/test-report --coverage` surface the gap later.

Delegate it to the `route-crawler` agent. The procedure:

1. **Preconditions.** A role with storage state at `tests/.auth/<role>.json`;
   without one, stop — crawling logged out finds the login page and nothing
   else. Caps: depth **2**, pages **15**. Both are hard.
2. **Collect same-origin link targets only.** Ignore off-origin links,
   `mailto:`, and anything that logs you out — ending your own session mid-crawl
   looks exactly like a broken app.
3. **Normalise before recording.** Drop the query string and fragment, and
   collapse a numeric or UUID segment to the app's own param form:
   `/invoices/1` → `/invoices/:id`. You are collecting routes, not records.
4. **Breadth-first**, stopping at whichever cap is reached first.
5. **Diff and append.** Compare against `tests/.cache/routes.txt` and append only
   what is new, deduped and sorted.

**Never submit a form, and never click a control named** delete / remove /
cancel / deactivate / archive / pay / send. A crawl reads the shape of the app;
it does not operate it. Return route paths — never the DOM, a snapshot, or page
text.

## Delegation

For an app with many feature areas, run `test-explorer` agents in parallel over
**the static pass only** — it is read-only and safe. The live crawl and the run
pass share one browser and must stay serial.

Give each explorer a slice of the route list and demand the `featuremap.txt`
line format back. Do not let it return file contents.
