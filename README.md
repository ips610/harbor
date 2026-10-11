# harbor

Manfath was eating 25–40% of my CPU just to show which ports were open, because it ran `lsof`
every 10 seconds. So I made harbor. It sits in the menu bar, shows every server listening on my
Mac, and lets me open, copy, share or kill each one. It reads everything straight from the
kernel, so it idles at about 0% CPU.

## What it does

The menu bar dropdown works like Manfath: ports grouped into dev servers, databases, runtimes
and so on, with open, share and kill on every row. Kill asks "confirm?" first and tells you which
process and folder it's about to stop. You can set a port range, hide processes you don't care
about, and choose how often it refreshes while open.

For the full view, open harbor from Applications (or "Open harbor…" in the menu) and it opens
`harbor.localhost:8470` in your browser. That page groups ports by project, with the folder, the
framework, uptime and memory for each one.

Share puts a port on the internet through a Cloudflare quick tunnel and gives you a link and a
QR code. It always asks first, and the tunnel stops when you unshare, when the server stops, or
when harbor quits. You need `cloudflared` for this (`brew install cloudflared`); harbor never
installs anything itself. ngrok works too if you have it set up and no cloudflared.

There's also a small "This Mac" part: memory and swap, the apps using the most memory, and a
warning if stuck (zombie) processes start piling up. The menu bar icon turns orange or red when
memory gets tight.

## Install

You need macOS 14 or newer and Xcode.

```sh
./build.sh
./install.sh
open /Applications/harbor.app
```

`install.sh` puts it in `/Applications` and replaces a running copy. Only one harbor runs at a
time; opening it again just brings up the page. Open at login is in the gear menu and off by
default. To rename the app, change `app.conf` and build again.

### Typing the address

The first time harbor runs it adds a small LaunchAgent, `~/Library/LaunchAgents/local.harbor.plist`.
launchd then holds `127.0.0.1:8470` and `[::1]:8470` for me, and nothing runs until something
connects. So I can quit harbor, type `harbor.localhost:8470` in Safari, and it starts and shows the
page. Typing the address (or using a bookmark) also signs the tab in; a link from another website
can't.

If `local.localhost.door` isn't already there (headroom adds the same one), harbor also adds that
agent. It answers on port 80 and sends `harbor.localhost` to `:8470` and `headroom.localhost` to
`:8460`, so the bare name works too. It exits ten seconds after the last visit.

If I quit harbor while its page is open, the page is told first and stops asking, so it doesn't
start harbor again behind my back.

### Uninstalling

```sh
launchctl bootout gui/$(id -u)/local.harbor
rm ~/Library/LaunchAgents/local.harbor.plist
rm -rf /Applications/harbor.app
```

Only remove the door if headroom isn't using it either:

```sh
launchctl bootout gui/$(id -u)/local.localhost.door
rm ~/Library/LaunchAgents/local.localhost.door.plist
```

If I move or delete the app, harbor fixes the agent's path the next time I open it.

## Why it's so light

It never runs `lsof`, `ps` or `netstat`. It asks the kernel directly (libproc, sysctl,
`host_statistics64`), so a full scan takes about 6 ms. With the menu and the page closed it only
does a tiny check once a minute, about 0.3 ms, for memory and stuck processes. Ports get scanned
only while you're looking at them. Sharing is the one thing that starts another program
(`cloudflared`), and only when you click it.

On my Mac (16 GB, lots of swap in use):

| | CPU | Memory |
| --- | --- | --- |
| Nothing open | 0.01% | 17 MB |
| Page open | about 0.5% | 19 MB |
| Menu open | 2.6% | 46 MB |

## Is it safe?

The page only listens on this Mac and needs a cookie that harbor sets when it opens the page, so
other websites can't talk to it. It can only stop or share processes it just showed you. Stop
sends a normal quit first and offers force kill only if that didn't work. For processes owned by
the system, like an antivirus, macOS asks for your password in its own dialog and harbor never
sees it. macOS's own processes are never offered.

## Limits

Ports opened by other users (root) don't show up, the same as `lsof` without sudo. CPU % takes a
second to appear after you open the menu or the page.

## Debugging

The app binary has a few flags for testing: `--dump`, `--bench N`, `--serve`, `--no-open`,
`--demo-menu --snapshot PATH` and `--test-stop PORT` (see `Sources/Harbor/DebugCLI.swift`). Test
runs never add a menu bar icon and use the next free port, so they can run next to an installed
copy.
