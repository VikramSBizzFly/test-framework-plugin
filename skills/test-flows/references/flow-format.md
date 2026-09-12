# The flow line format

`tests/.cache/flows.txt` — one flow per line, **nine tab-separated fields**.
Tab, not pipe: `steps` and `code path` are pipe-separated lists themselves.

```
id <TAB> name <TAB> actor <TAB> trigger <TAB> steps <TAB> code path <TAB> writes <TAB> branches <TAB> cases
```

| Field | Rule |
| --- | --- |
| `id` | `FLOW-<PREFIX>-NNN`, from the featuremap's prefix. Stable forever; never renumber. |
| `name` | What a person would call it, lowercase. Prefix `[priv] ` if it crosses a privilege boundary. |
| `actor` | The role that can start it: `nobody`, `normal user`, `admin`, or the project's own role name. |
| `trigger` | What starts it: a nav click, a form submit, a cron, a webhook, a redirect from elsewhere. |
| `steps` | The ordered path, `\|`-separated. Routes and actions, not prose. |
| `code path` | `\|`-separated hops, each `path:line symbol`, ending at the data layer or the outbound call. |
| `writes` | What changes: tables, files, queues, emails, third-party calls. `-` if it only reads. |
| `branches` | `\|`-separated failure and alternate paths, each citing `path:line`. `-` if there genuinely are none. |
| `cases` | Comma-separated case ids covering this flow. Left empty by `flow-mapper`; filled by `case-author`. |

## Worked example — a login flow

```
FLOW-AUTH-001	log in	nobody	submits the login form	/login|POST /login|/dashboard	app.py:71 do_POST|app.py:78 USERS lookup|app.py:83 SESSIONS[sid]	SESSIONS	wrong password -> app.py:86 re-renders /login with an error|unknown user -> app.py:84 same path	AUTH-001,AUTH-004
```

Read back: anyone can start it, it is three steps, it runs through one handler
into the session store, it writes a session, and it has exactly two failure
branches — both cited.

## Worked example — a flow nobody tests

```
FLOW-PAY-002	[priv] run payroll	admin	clicks Run on /payroll	/payroll|POST /payroll/run|/payroll?done=1	payroll.py:40 run_payroll|payroll.py:61 Ledger.post	ledger, emails to staff	no funds -> payroll.py:55 aborts and flashes|already run this month -> payroll.py:47	
```

`cases` is empty, so this rolls up as **not covered** in the workbook — an admin
flow that writes to a ledger and emails staff, with nothing testing it. That is
the single most useful row the Flows sheet produces.

## What not to write

- A branch you did not find in the code. Cite `path:line` or leave it out.
- A step that is a function call rather than something the user or system does.
- Framework internals — routing, middleware, the ORM. Stop at the data layer.
- One flow per route. If two lines differ only by a route segment, they are one
  flow with more steps.
