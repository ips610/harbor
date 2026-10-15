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
  you ask, and the tunnel stops when harbor does. harbor never installs
  anything but its own update (see Update now below).
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
  same rules. `ls`, `kill`, `open`, `scan`, `check` and `watch` never talk to
  the running app and never read the session file. The commands that change
  something (`share`, `unshare`, `extend`, `password`, `tunnel`, `start`,
  `rename`, `group`) reach the app the way its page does: on its own loopback
  port, with the owner's session file (mode 0600, this account only). The app
  answers with the same checks as for a click: the port must be one it lists,
  durations are its three choices, a password needs 8 characters, a restart
  shows the real program first. Whoever can read that file as this account could
  already drive the page; another account cannot. A password is never an
  argument (it would sit in shell history and in `ps`): a prompt that does not
  echo, one line of stdin, or one the app makes with `--random`, printed once.
  `harbor kill` asks first, re-checks that the process is still the
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
- The bell ("tell me when it stops") is per server and off until you click
  it. It is pinned to the process, its start time and the port, like a share.
  The notification's text is harbor's own name for the server and the port,
  nothing the server sent. Bells are kept in memory only.
- Start again. While one of your own servers runs, harbor keeps how it was
  started: its program, its arguments as an array, its folder and its
  environment. All of it stays in harbor's memory: never in a file, in the
  settings, in the note for the command line or in a log, and the
  environment's values are never shown and never sent to the page. At most 20
  stopped servers, each for 24 hours, all gone when harbor quits. Never
  remembered: macOS's own processes, another user's, Docker and its
  containers, harbor itself and what it runs for a public link, an app's
  helpers, anything harbor wouldn't let you stop, and any process that runs in
  a sandbox (a coding agent's, say): harbor would start it outside that
  sandbox.
- The arguments, the environment and the path that was exec'd come from the
  process's own memory, so the process could have written anything there.
  Which program runs is the kernel's own word instead. The exec'd path is used
  only when it is a whole path that leads to that same file (a virtualenv's
  python link); one that leads anywhere else is not remembered at all.
- A request to start one names the list's entry by an id harbor made up for
  this run, and nothing else: no command, path or argument is read from it.
  It needs the signed-in page (both halves of the session), a POST and
  harbor's own header, like every other action. A network visitor's session
  is no session there: the network listener has no path to harbor's own calls
  at all. One start at a time: while the process harbor started for an entry
  is alive, another request for it starts nothing.
- Before it starts, harbor asks and shows what will run: the program by where
  it really is, on a line of its own (never by the name the process gave
  itself); every argument, in quotes whenever it is empty or has a space, a
  quote or anything a shell would read, with characters that can't be seen
  shown as a mark; and when the text is cut, by how many characters. It says
  the environment comes back as it was, and names (names only) any of these
  that are set, because they make a program load code: `NODE_OPTIONS`,
  `PYTHONSTARTUP`, `PYTHONPATH`, `BASH_ENV`, `ENV`, `RUBYOPT`, `PERL5OPT`,
  `JAVA_TOOL_OPTIONS`, `DYLD_INSERT_LIBRARIES`, `DYLD_LIBRARY_PATH`,
  `LD_PRELOAD`. If the program's file changed since harbor saw it run (a
  rebuild does that), it says so; that is said, not refused.
- It is started with the remembered program, arguments, folder and
  environment directly, never through a shell and never from text that is
  parsed. harbor refuses when the program or the folder is gone, is no longer
  a regular file or a folder, or now really is somewhere else (a link that
  wasn't there, or one that leads elsewhere), and when anything is already
  listening on that port.
- It also refuses when another account could have swapped the program or its
  folder. From each of them up to `/`, every step has to be yours or root's,
  not writable by everyone (a folder with the sticky bit, like `/tmp`, apart),
  and not writable by a group other than `admin` or `wheel`. `staff` is every
  account on the Mac, so staff-writable is refused; an admin can become root
  anyway, and Homebrew's folders are admin's. This is about the program and
  the working folder only. The scripts and other files the program reads are
  not looked at.
- A server started this way writes to `~/Library/Logs/harbor/<name>-<port>.log`
  (mode 0600, in a folder of mode 0700). The name in it is one of harbor's own
  labels. The folder has to be a real folder of yours: a link there is
  refused, not followed. Whatever is at the log's path is unlinked and the log
  is made new, so a link or a second name for another file put there never
  gets that file emptied. harbor empties the log when it passes 5 MB. The
  server writes to the file itself and keeps running when harbor quits, so
  the 5 MB limit holds only while harbor runs.
- Update now runs only on your click, and is offered only to the copy in
  Applications itself, in a folder you can write to, and only when macOS's
  Security framework says that copy is signed with a certificate (not ad-hoc,
  and with certificates in its signature). A copy with a throwaway signature
  has nothing to hold a download to, so it is never offered there. It doesn't
  start while harbor is in the middle of stopping something for you.
- What decides whether a download is installed is its signature. harbor asks
  macOS's Security framework, inside its own process, whether the unpacked app
  meets the designated requirement of the harbor that is running (every
  architecture, nested code, strict). So the new app has to be signed with the
  same key. It also has to have the same bundle id, the version of the release
  that was asked for, and a version strictly newer than the running one.
- A zip also carries who may write: access lists, write permission for a group
  or for everyone, set-user-id bits. None of that is covered by the signature,
  so before the check harbor removes all of it from what was unpacked, item by
  item and never through a link. What gets installed is writable by you only.
- Before that: the file comes over https from
  `github.com/ips610/harbor/releases/download/v<version>/`, with a version
  made of digits and dots and one of two fixed file names. A redirect is
  followed only to https on port 443 of `github.com` or of a host ending in
  `.githubusercontent.com`. More than 30 MB is refused. The zip's SHA-256 has
  to match the release's `SHA256SUMS`; that only catches a broken download,
  since whoever could change the zip could change the list.
- The zip is unpacked by macOS's `ditto` into a new folder of mode 0700 beside
  the app. Three things protect here: `ditto` keeps what it writes inside that
  folder; what came out has to be exactly one real folder called
  `harbor.app`; and the signature check above. harbor ends `ditto` when it has
  written more than 200 MB or has run for 60 seconds. harbor also reads the
  zip's own list of contents first and refuses an odd one early, but that
  list is only what the zip says about itself, and protects nothing.
- The swap is two renames. If the new app can't be put in place, the old one
  is put back. The old app then goes to the Trash. If the Trash won't take
  it, it stays where it is, in that folder beside the app, and the new copy
  says once exactly where. The download and what was unpacked from it are
  always deleted. Any failure before the swap leaves the installed app
  exactly as it was, and harbor says why. Nothing from the release (a name, a
  version, its notes) is passed to a shell or shown as markup.

## Verifying a download

Each release has a `SHA256SUMS` file. After downloading, check it:

```sh
shasum -a 256 -c SHA256SUMS
```
