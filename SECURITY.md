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
- Any server of a project can go on the network, each under its own name and
  each for one server: the process and the port it was turned on for.
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
- One password per project, and one sign-in. A page calling its own back end
  is another site to the browser, which sends no cookie and asks first without
  one. So a session remembers its project and the address it was signed in
  from, and a request to another shared name of that project gets in without a
  cookie when all of this holds:
  - it comes from that address (the connection's own, never a header);
  - it says it comes from one of the project's own pages on the network: its
    `Origin`, or with no `Origin` the start of its `Referer`, is exactly a
    shared name of the same project. `null`, another site, another project's
    name, or neither header: the sign-in page. So another website open on a
    signed-in device can't read or call the project's other servers, unless the
    project's own page sends the browser there (an open redirect in it, say);
  - the session is in use from that address: its cookie came from there in the
    last 15 minutes, or a connection it came with is still open. Requests let
    in this way don't count as use.

  A name opens with its own cookie, or this way through a session on another
  name of the project; a device signed in on one name only still needs that
  name's cookie there. Devices that reach harbor from one address (behind a
  hotspot, or a router doing NAT) count as one device, and a program on such a
  device that isn't a browser can write any `Origin` it likes. A device that
  takes over a signed-in device's address within 15 minutes of its last use
  gets the project's other servers.
- A visitor's session is an HttpOnly cookie harbor keeps in memory for 12
  hours, and the project never sees it. It is a session only from the address
  it was signed in from: from any other address the visitor gets the sign-in
  page (no try is counted) and signs in again, which ends the session that
  browser had and cuts what it had open. Turning sharing off, changing or
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
- Network passwords are kept in a file only your account can read
  (`~/Library/Application Support/local.harbor/network-passwords`, mode 0600),
  like the sign-in session, never in settings or logs. The Keychain would ask
  for your login password after every update, because harbor isn't signed with
  an Apple Developer ID. A password that can't be read is never treated as no
  password: the project stays off the network until you set a new one, and
  the file that couldn't be read is kept beside the new one as
  `network-passwords.unreadable`. One you type needs 8 characters and can't be
  one of the obvious ones.
- On network is plain http. The password keeps out people browsing the
  network. Someone capturing its traffic can read the pages and try passwords
  against a captured sign-in at their own pace. A signed-in visitor's session
  they can reuse only if they also take over that device's address. Someone
  who can change traffic can show a fake sign-in page and learn
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
