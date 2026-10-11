# harbor

Manfath was eating 25–40% of my CPU just to show which ports were open, because it ran `lsof`
every 10 seconds. So I made harbor. It sits in the menu bar, shows every server listening on my
Mac, and lets me open, copy, share or kill each one. It reads everything straight from the
kernel, so it idles at about 0% CPU.

## What it does

The menu bar dropdown works like Manfath: ports grouped into dev servers, databases, runtimes
and so on, with open, share and kill on every row. Kill asks "confirm?" first and tells you which
process and folder it's about to stop. You can set a port range and hide processes you don't care
about. If you tick "macOS services", they're marked plainly: a "macOS service" badge on their card,
a grey card style and a macOS pill on each row.
The badge always counts exactly the rows the list shows, with the same range and filters.

It refreshes every 5, 15 (the default), 30 or 60 seconds while the menu or the page is open, or
every N seconds if you type your own (5 to 3600), or only when you press refresh. The menu and the
page use the same setting. If the menu bar badge is on (a count or a dot), harbor also scans at that
interval with everything closed, so the number stays right. With the badge off, nothing is scanned
until you look.

Like Manfath, it shows the network address in plain sight: the header says "On your network:
172.17.131.1 · Name.local" (or "Not on a network"), and each row shows where other devices reach it,
like `172.17.131.1:3000` (click to copy), or "this Mac only". It's read again on every scan, so a
new Wi-Fi shows up on the next refresh.

Every row has a QR button, and the QR is also in a row's details. A server on all interfaces gets
its network address as a QR for your phone on the same Wi-Fi. One bound to `127.0.0.1` can't be
reached from a phone, so it says so and offers share; once shared, the QR opens the public link.

For the full view, open harbor from Applications (or "Open harbor…" in the menu) and it opens
`harbor.localhost:8470` in your browser. That page groups ports by project, with the folder, the
framework, uptime and memory for each one. The tab shows harbor's icon (the ferry from the app
icon) and the port count.

Appearance is Auto, Light or Dark, in the gear menu or on the page (top right, and in Settings).
The menu and the page share it. Auto follows macOS. The menu bar icon always follows the menu bar.

harbor shows in the Dock by default. Clicking the Dock icon opens the page. "Show in Dock" in the
gear menu or the page's settings turns that off, and then it lives only in the menu bar.

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
time; opening it again just brings up the page. Open at login is in the gear menu and the page's
settings, and off by default. To rename the app, change `app.conf` and build again.

`build.sh` signs with my own certificate ("IPS Local Apps") when that's in the keychain, so
macOS remembers what you allowed harbor to do after a rebuild. Without it, the app gets a
throwaway signature. Set `SIGN_ID` to use a different certificate.

### Typing the address

The first time harbor runs it adds a small LaunchAgent, `~/Library/LaunchAgents/local.harbor.plist`.
launchd then holds `127.0.0.1:8470` and `[::1]:8470` for me, and nothing runs until something
connects. So I can quit harbor, type `harbor.localhost:8470` in Safari, and it starts and shows the
page. Typing the address (or using a bookmark) also signs the tab in; a link from another website
can't.

If `local.localhost.door` isn't already there (headroom adds the same one), harbor also adds that
agent. It answers on port 80 and sends `harbor.localhost` to `:8470` and `headroom.localhost` to
`:8460`, so the bare name works too. It exits ten seconds after the last visit.

When I quit harbor (from the menu, with ⌘Q or from the Dock), it stays quit. An open page that
asks in the background is told harbor has quit and stops asking, so it doesn't start harbor again
behind my back. Only typing the address or opening the app starts it again.

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
`host_statistics64`), so a full scan takes about 6–10 ms. With the menu and the page closed it only
does a tiny check once a minute, about 0.3 ms, for memory and stuck processes. Ports get scanned
only while you're looking at them, or at your refresh interval if the badge is on. Sharing is the one thing that starts another program
(`cloudflared`), and only when you click it.

On my Mac (16 GB, lots of swap in use):

| | CPU | Memory |
| --- | --- | --- |
| Nothing open, badge off | 0.01% | 9 MB |
| Nothing open, badge on (every 15 s) | 0.15% | 20 MB |
| Page open (every 15 s) | 0.15–0.25% | 20 MB |
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
`--demo-menu --snapshot PATH`, `--demo-lan PORT`, `--theme light|dark`, `--show-system` and
`--test-stop PORT` (see `Sources/Harbor/DebugCLI.swift`). Test runs never add a menu bar or Dock
icon, never take the keyboard, don't save settings, and use the next free port, so they can run
next to an installed copy.
