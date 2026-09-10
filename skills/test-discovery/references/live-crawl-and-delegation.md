# Live crawl and delegation detail

## Featuremap line format

```
invoice   INV   /invoices /invoices/1 /invoices/new   src/app/invoices
payroll   PAY   /payroll /payroll/run                 src/app/payroll
```

## Step 4 — live crawl, only if needed

Only when static discovery clearly missed something — routes built at runtime, a
SPA with no route table. Log in once, snapshot, follow links to depth 2, and
stop. This is expensive; prefer to be wrong on the side of fewer routes and let
`/test-report --coverage` surface the gap later.

## Delegation

For an app with many feature areas, run `test-explorer` agents in parallel over
**the static pass only** — it is read-only and safe. The live crawl and the run
pass share one browser and must stay serial.

Give each explorer a slice of the route list and demand the `featuremap.txt`
line format back. Do not let it return file contents.
