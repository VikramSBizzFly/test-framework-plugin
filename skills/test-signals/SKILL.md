---
name: test-signals
description: Add accessibility, performance and visual-regression assertions to a browser case. Use when authoring an a11y/perf/visual case, when a page case already opens a route and the extra assertion is nearly free, or when deciding whether visual regression is worth turning on.
---

# Signals

Three assertions riding on browser cases you already run. Only add them where
they cost close to nothing — that is the whole pitch.

All of them stay `type=page`; the signal lives in `tags` (`a11y`, `perf`,
`visual`, `responsive`). `type` is only ever `page` or `api` — see **test-authoring**.
Delegate the browser work: accessibility to the `a11y-auditor` agent, a
baseline diff to the `visual-reviewer` agent. Neither the tree nor the image
belongs in the main thread.

## Accessibility (`tags=a11y`) — nearly free

The Playwright MCP returns an accessibility tree with every snapshot you
already take for a `ui` case. Asserting on it costs no extra navigation.

Assert:
- every form input has an accessible name (label, `aria-label`, or
  `aria-labelledby`) — a missing one blocks a screen-reader user outright
- every interactive control (button, link, custom widget) is reachable in the
  tree — not `aria-hidden` while still clickable
- heading levels don't skip (`h1` → `h3` with no `h2`)

Ignore: colour contrast, ARIA role nitpicks below `WCAG A`, and anything only
a visual diff would catch — that noise buries the three checks above that
actually block a user. One `a11y` case per route, not per element.

## Performance (`tags=perf`) — capture what the browser already timed

Capture navigation timing (`domContentLoaded` / `load`, or the MCP's own
timing if it exposes one) on a case you're already running — do not add a
dedicated page load just to time it.

Compare against `perf_budget_ms` in `tests/framework.json` (default `3000`).
Over budget is a `FAIL`, not a warning — a budget nobody enforces is decor.
Record the actual ms in the result row so a regression shows a number, not
just red.

## Responsive (`tags=responsive`) — three widths, five failures

Delegate to the `responsive-auditor` agent, one call per route. It opens the
route at **390 / 768 / 1280** and fails only on what a person could not use:
horizontal overflow, clipped or overlapping text, a control pushed off-screen,
a nav that never collapses, and tap targets under 24px on the phone width.

**Reflow is not a failure** — a stacking sidebar or a one-column grid is the
design working. The failing width goes in the case's `viewport` column, which
the state schema has always had and nothing used until now.

## Visual regression (`tags=visual`) — opt-in, and the one signal that costs tokens

Baselines live at `tests/baselines/<case-id>@<width>.png` — one per width, so a
phone render is never compared against a desktop baseline. A run diffs the current
screenshot against the baseline; a diff is not itself a verdict — it is a
manual review, because the model has to look at the image to say if it
matters. That review is the only thing in this whole framework that spends
tokens on a passing-looking case.

**Turn it on** for a small, deliberate set: the pages where markup is stable
and a pixel regression is the whole risk — a marketing page, a checkout step,
a chart. **Leave it off** everywhere layout is driven by real data (tables,
dashboards, anything with dates or user content) — every run diffs against
noise, and the diff-review cost recurs forever, not once. When a baseline
goes stale on purpose (an intended redesign), regenerate it explicitly; never
silently on a failed diff — that defeats the point of having one.
