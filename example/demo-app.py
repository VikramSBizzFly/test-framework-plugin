"""A tiny broken web app, for trying the test framework on.

It has a login, two users with different permissions, and TWO DELIBERATE BUGS
for the test framework to find on its own:

  /payroll   no permission check at all - anybody can read the salaries
  /reports   refuses you correctly, but says so with HTTP 200

Both pages return HTTP 200 to a logged-out visitor. One is a serious leak and
the other is working exactly as intended. A test that only reads status codes
cannot tell them apart, so it must get one of them wrong. Reading the actual
page is the only way to know which is which -- that is why this framework
opens a real browser.

Run it with:   python example/demo-app.py
Then open:     http://127.0.0.1:8731

Logins:  a@x.com / pw1   (admin)
         u@x.com / pw2   (normal user)

You only need Python for THIS demo app. The test framework itself does not
need Python, or Node, or anything else.
"""

import http.server
import urllib.parse
import uuid

SESSIONS = {}
USERS = {"a@x.com": ("pw1", "admin"), "u@x.com": ("pw2", "user")}

LOGIN_PAGE = """<!doctype html><title>Login</title>
<h1>Demo app</h1>
<form method=post action=/login>
  <input type=hidden name=_csrf value=tok123>
  <p><input name=email placeholder="email"></p>
  <p><input name=password type=password placeholder="password"></p>
  <button type=submit>Sign in</button>
</form>
<p>Try a@x.com / pw1 (admin) or u@x.com / pw2 (user)</p>"""


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # keep the terminal quiet

    def who(self):
        """Return the role of the logged-in user, or None."""
        cookies = self.headers.get("Cookie", "")
        for part in cookies.split(";"):
            part = part.strip()
            if part.startswith("sid="):
                return SESSIONS.get(part[4:])
        return None

    def reply(self, code, body="", headers=()):
        self.send_response(code)
        for key, value in headers:
            self.send_header(key, value)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body.encode())

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        role = self.who()

        if path == "/":
            return self.reply(200, "<h1>Demo app</h1><a href=/login>Log in</a>")

        if path == "/login":
            return self.reply(200, LOGIN_PAGE)

        if path == "/dashboard":
            if role:
                return self.reply(200, f"<h1>Dashboard</h1><p>You are: {role}</p>")
            return self.reply(302, "", [("Location", "/login")])

        if path == "/admin":
            # Correct: only admins get in.
            if role == "admin":
                return self.reply(200, "<h1>Admin panel</h1>")
            if role:
                return self.reply(403, "<h1>Forbidden</h1>")
            return self.reply(302, "", [("Location", "/login")])

        if path == "/payroll":
            # THE BUG. No permission check at all. Anyone can read this,
            # including someone who is not logged in.
            return self.reply(200, "<h1>Salaries</h1><p>alice 120k, bob 95k</p>")

        if path == "/reports":
            # The tricky one, and the reason tests run in a real browser.
            #
            # This page refuses you CORRECTLY -- it just says so with HTTP 200
            # instead of 403. /payroll below also returns 200, and it leaks
            # every salary. Same status code, opposite meanings.
            #
            # So a test that only reads the status code has to guess, and it
            # guesses wrong here: it reports a bug on a page that is fine.
            # Only reading the rendered page tells the two apart.
            if role == "admin":
                return self.reply(200, "<h1>Reports</h1><p>Q3 revenue: 4.2M</p>")
            return self.reply(200, "<h1>Access denied</h1><p>Ask an admin.</p>")

        if path.startswith("/api/"):
            if role:
                return self.reply(200, '{"ok": true}')
            return self.reply(401, "unauthorized")

        return self.reply(404, "<h1>Not found</h1>")

    def do_POST(self):
        if urllib.parse.urlparse(self.path).path != "/login":
            return self.reply(404, "<h1>Not found</h1>")

        length = int(self.headers.get("Content-Length", 0))
        form = urllib.parse.parse_qs(self.rfile.read(length).decode())
        email = form.get("email", [""])[0]
        password = form.get("password", [""])[0]

        if email in USERS and USERS[email][0] == password:
            session_id = uuid.uuid4().hex
            SESSIONS[session_id] = USERS[email][1]
            return self.reply(302, "", [
                ("Location", "/dashboard"),
                ("Set-Cookie", f"sid={session_id}; Path=/"),
            ])

        return self.reply(401, "<h1>Wrong email or password</h1>")


if __name__ == "__main__":
    print("Demo app running at http://127.0.0.1:8731")
    print("Press Ctrl+C to stop it.")
    http.server.HTTPServer(("127.0.0.1", 8731), Handler).serve_forever()
