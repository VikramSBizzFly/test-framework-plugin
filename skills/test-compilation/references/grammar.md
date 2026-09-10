# Recipe grammar

One verb per line, plain text, no quoting rules beyond `"..."` around
multi-word literal text. Comments are not needed — a recipe is generated, not
hand-edited.

```
nav <path>                         direct navigation, storage state already loaded
fill <type>:<name> <value>         <value> is a literal, or $role.username / $role.password
click <type>:<name>
select <type>:<name> <value>
check <type>:<name>
uncheck <type>:<name>
expect url <path>
expect text <type>:<name> "<text>"
expect not-text <type>:<name> "<text>"
expect visible <type>:<name>
expect absent <type>:<name>
expect any-of [ <condition>, <condition>, ... ]
```

`expect not-text` passes when the named element's text does **not** contain
the literal — use it for "the page must not show the data that belongs to
someone else" style refusals, where there is no fixed string to match.

`expect any-of [ ... ]` passes if any one nested condition passes. Its
condition list uses the same verbs minus the `expect` prefix, e.g.
`expect any-of [ url /login, text alert:error "Forbidden", text alert:error "Access denied" ]`.
This exists because apps disagree on how they refuse: some redirect to
login, some render a banner, some show a 403 page with its own wording —
compiling one hard-coded string would make the case brittle to phrasing the
case never claimed to test.

`<type>:<name>` is the accessible role and name exactly as the page model
listed it — `textbox:Email`, `button:Sign in`, `link:Forgot password?`. The
compiler copies these straight out of the page model; it never invents a
selector. If a case needs an element the page model does not have, that route
needs re-modeling, not a guessed selector.

`expect` lines only ever appear last, and there is normally exactly one.
Two are acceptable when the case genuinely asserts two independent outcomes
(e.g. `expect url` and `expect text` after a redirect that also shows a
banner) — never as a substitute for splitting the case.

## Worked example

Case `AUTH-014`: *"a valid login lands on the dashboard"*, who `normal
user`, route `/login`.

```
nav /login
fill textbox:Email $role.username
fill textbox:Password $role.password
click button:Sign in
expect url /dashboard
```

Case `INV-009`: *"an invoice amount under the minimum is rejected"*,
who `normal user`, route `/invoices/new`.

```
nav /invoices/new
fill textbox:Amount 0
click button:Save
expect text alert:error "must be greater than 0"
```

Neither recipe contains a role name, an intermediate assertion, or a click
that exists only to navigate. That is the whole target.

## Worked example — a rendered permission refusal

Case `PERM-ADM-003`: *"log in as normal user and open the admin settings
page — should not open, I am not allowed to see this"*, who `normal user`,
route `/admin/settings`. A curl status check would miss this if the app
serves the settings page at 200 with an "Access denied" body, or guards it
client-side after the shell has already loaded:

```
nav /admin/settings
expect any-of [ url /login, text alert:error "Forbidden", text alert:error "Access denied" ]
```

If the page instead renders normally but must not show another tenant's
data:

```
nav /invoices/1042
expect not-text cell:owner "Acme Corp"
```

## Compiling from the page model

The page model gives you the element inventory and validation constraints;
the case's `what to do`/`what should happen` columns give you the scenario.
Translate mechanically:

- a `what to do` cell like `Fill Email | Fill Password | Click Sign in`
  becomes one `fill`/`click` line per segment, in order
- a field's boundary constraint (`minlen=8`, `required`, `type=email`) is
  what justifies a boundary case's `fill` value — pull the value from the
  case row, not from the page model; the model only tells you *which*
  constraint is being tested
- `what should happen` becomes the trailing `expect` line(s); pick
  `expect url` for navigation, `expect text`/`expect not-text` for a
  message or its absence, `expect visible`/`expect absent` for an element
  appearing or disappearing, `expect any-of` when the case only says "should
  not open" without naming the app's specific refusal mechanism

If `what to do`/`what should happen` can't be mapped onto the model's
element inventory at all, do not guess — leave the case `status=new` and
note why.
