# Login flows, and the two session artifacts

> `tf.sh` = `"$CLAUDE_PLUGIN_ROOT/scripts/tf.sh"` (not on PATH).

## 1. The curl path — try this first

`tf.sh login <role>` handles a classic form-post login, which covers most
server-rendered apps and many SPAs. It:

1. fetches `login.path` from `tests/credentials.json` (default `/login`),
2. scrapes the username and password **field names** off the form rather than
   assuming them,
3. extracts a CSRF token if one is present — it knows `_csrf`, `csrf_token`,
   `csrfmiddlewaretoken`, `authenticity_token` and `__RequestVerificationToken`,
4. posts the credentials, then verifies `login.success_indicator` returns 2xx,
5. saves a Netscape cookie jar to `tests/.auth/<role>.cookies`.

A non-2xx verification deletes the jar and fails loudly. That usually means a
JavaScript login, SSO or 2FA — go to the browser path.

## 2. Convert to storage state — always

```sh
tf.sh storage-state <role>
```

Rewrites the jar as Playwright storage state at `tests/.auth/<role>.json`:

```json
{ "cookies": [ { "name": "...", "value": "...", "domain": "...", "path": "/",
  "expires": -1, "httpOnly": false, "secure": false, "sameSite": "Lax" } ],
  "origins": [] }
```

Prefer this over reading cookies out of a browser: the jar carries `HttpOnly`
cookies, which `document.cookie` cannot see.

## 3. The browser path — only when the curl path failed

Navigate the login route, fill the fields from `tests/credentials.json`, submit,
and confirm the success indicator by snapshot. Then capture
`localStorage`/`sessionStorage` and the readable cookies in one evaluate, and
write the same shape with the storage entries under `origins`.

If the app keeps its session in an `HttpOnly` cookie the browser cannot read,
say so rather than writing a storage state that will not authenticate — a file
that exists but does not work is worse than one that is missing, because
`preflight` will report the role as ready.

## 4. Verify

Navigate one protected route with the storage state loaded and confirm you did
not land on the login page. Only then report success.
