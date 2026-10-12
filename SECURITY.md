# Security

## Reporting a problem

If you find a security problem in harbor, please tell me privately first. On
GitHub, go to the repo's **Security** tab and choose **Report a vulnerability**.
I'll reply within 7 days.

Please don't open a public issue for it until there's a fix.

Only the latest release is supported. If you're on an older one, update first.

## What harbor does to stay safe

- The page listens only on this Mac (`127.0.0.1` and `[::1]`), never on the network.
- A browser tab is signed in by two things together: an HttpOnly,
  SameSite=Strict cookie, and a key the page keeps in localStorage. Both come
  from a one-time code in a link that harbor opens in your browser itself, and
  both are kept in one 0600 file. A cookie alone isn't tied to a port on
  localhost, so the key is what ties the session to harbor's exact address.
  The page itself holds no secrets, and no website can get either half.
- Requests are checked against harbor's own Host names (so a rebinding attack
  can't reach it), POSTs need harbor's own header, and the page's one script
  runs under a CSP nonce.
- Project names (`<name>.localhost`) are answered by a second listener, also
  only on `127.0.0.1` and `[::1]`. It refuses every Host that isn't a
  `.localhost` name, forwards only to ports harbor lists itself (never to
  harbor's or headroom's own pages), and has no access to the session. Renames
  need the signed-in page.
- On network (`<name>.local`) is off until you turn it on for a project, and it
  never comes back on by itself. While something is on, one more listener is
  open on port 80 of every interface (the only way to have port 80 without
  root). It answers only connections that arrived on the address harbor
  announced, only for a Host that is exactly a shared name, and it knows
  nothing of harbor's page, the `.localhost` names or the projects that aren't
  on. The door for the `.localhost` names is unloaded for the moment that
  listener is bound and loaded again right after (launchd's loopback sockets
  on port 80 would otherwise refuse it); only the copy in Applications does
  that. If another program already has port 80, nothing is shared. Without
  root, no other program can bind the announced address on port 80. harbor
  also holds port 80 on IPv6 while sharing, serves nothing there, and says so
  if another program had it first.
- A share is for one server: the process and the port it was turned on for.
  When that server is gone, or another program listens on its port too, the
  sharing stops. It never moves to another server.
- With a password, harbor's own sign-in page comes before anything reaches the
  project, WebSockets included. The visitor answers a challenge
  (PBKDF2-HMAC-SHA256 with 50,000 rounds, then HMAC-SHA256 over the name and
  the challenge), so the password itself is never sent. A challenge is signed
  by harbor, lasts two minutes and signs in once. harbor keeps nothing for a
  challenge that was only asked for, so asking for many is in nobody's way. The
  two sign-in calls are taken only from the sign-in page itself (its exact
  Origin, as JSON), so another website can't spend a visitor's tries.
- A visitor's session is an HttpOnly cookie harbor keeps in memory for 12
  hours, and the project never sees it. Turning sharing off, changing or
  removing the password, renaming, or joining another network ends the
  sessions and cuts every connection that was open for the name. A WebSocket with
  nothing passing for 10 minutes is closed. The cookie belongs to the name,
  not to a port (a cookie can't), so the visitor's browser also sends it to
  anything else this Mac serves under that name.
- Wrong passwords: five from one address lock that address for 5 minutes,
  doubling up to an hour. More than 30 in 10 minutes for one name, from
  anywhere: harbor tells you, and for 10 minutes every sign-in to that name
  takes 2 seconds longer. Only a try with a good challenge and a wrong answer
  counts. One address gets 24 connections at a time, everyone together 128,
  and a request has 5 seconds to arrive.
- Passwords are kept in the Keychain, never in settings or logs. One you type
  needs 8 characters and can't be one of the obvious ones.
- On network is plain http. The password keeps out people browsing the
  network. Someone capturing its traffic can read the pages, reuse a signed-in
  visitor's session, and try passwords against a captured sign-in at their own
  pace. Someone who can change traffic can show a fake sign-in page and learn
  the password. While a password is set, anyone on the network can get in the
  way of sign-ins; they can't get in. For anything private, use share.
- harbor only stops or shares a process it just showed you, and it re-checks the
  process is still the same one right before it acts, so a reused PID is safe.
- Stopping a process owned by another user uses macOS's own password dialog,
  fresh each time; harbor never sees the password. macOS's own processes are
  never touched.
- Sharing a port runs `cloudflared` (or `ngrok`) from a fixed path, only when
  you ask, and the tunnel stops when harbor does. harbor never installs anything.

## Verifying a download

Each release has a `SHA256SUMS` file. After downloading, check it:

```sh
shasum -a 256 -c SHA256SUMS
```
