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
- A public link, and a server on the network, can be given 30 minutes or an
  hour. The deadline is a time on the clock, so a Mac that slept through it
  stops the share when it wakes. Only your own "+30 min" moves it, and a
  rename doesn't. Any other length is refused, not read as "for ever".
- The status line beside a row ("200 · Storefront") comes from one `GET /`
  that harbor sends itself, to the server's own address on this Mac, and only
  while you are looking at that row: its details open in the menu, or the row
  on screen on the page. At most six at a time and once a minute per row;
  nothing from a timer. The request carries no cookie and no credentials, no
  redirect is followed, at most 64 KB is read, and it gives up after 3
  seconds. It is never sent to a database, to an app's own helper port, to a
  port browsers refuse, to macOS's services, or to harbor's or headroom's own
  ports. The title is cut to 80 characters, stripped of control and
  direction-changing characters, and only ever shown as text. Neither the
  title nor a redirect's target is logged.
- Docker's containers are named from one request, `GET /containers/json`, to
  your own Docker socket (a unix socket this account owns). That is the only
  thing harbor ever writes to it; the `docker` command is never run. It is
  asked only while one of Docker's processes is listening, at most every 15
  seconds, with a one-second limit. What comes back is treated like any other
  outside text. Only a process inside the real Docker.app or OrbStack.app (in
  `/Applications` or `~/Applications`), or Lima's own `limactl` under
  Homebrew, counts as Docker's. The process on a container's port is Docker
  itself, so harbor offers no kill there and refuses a kill, or a quit, asked
  for through that row from the page or the command line. Docker Desktop can
  still be quit on purpose from the list of apps, and harbor says first that
  every container stops with it. The `docker stop` hint names the container
  only when its name is one Docker itself would allow. A container never
  takes a `.localhost` name from a project folder or an app that wants the
  same one at the same time.
- A container on the network is pinned to its container id as well. While
  anything is on the network harbor scans at least every 15 seconds, whatever
  the refresh setting and whatever is open. So when another container gets
  that port, the share stops within 15 seconds, not at once.
- The `harbor` command runs in its own process with the same scanner and the
  same rules. It never talks to the running app and never reads the session
  files. `harbor kill` asks first, re-checks that the process is still the
  one it asked about before any signal, never touches macOS's processes,
  harbor, Docker or another user's processes, and has no administrator path.
  What it prints is stripped of escape sequences.
- The running app leaves the command one small file,
  `~/Library/Application Support/local.harbor/shared` (mode 0600): which row
  goes by which name, and what is on the network or behind a public link. No
  passwords, no session. The command believes it only while the process that
  wrote it is still that process, and takes a name from it only if it is a
  plain label.
- Installing the command makes one symlink to the app's own binary in
  `/usr/local/bin`, or in `~/.local/bin` when that one can't be written to.
  No administrator password. A file or link called `harbor` that isn't
  harbor's own is never replaced or removed.

## Verifying a download

Each release has a `SHA256SUMS` file. After downloading, check it:

```sh
shasum -a 256 -c SHA256SUMS
```
