# harbor

A menu bar app that shows what is listening on your Mac's ports and lets you open, copy or stop each one. It replaces Manfath, which rescanned with `lsof` every 10 seconds and used 25–40% CPU.

- **Menu bar dropdown**, modelled on Manfath. It has a "Listening on localhost" header, search, and sections (Dev servers, Databases, Runtimes, App helpers, Other). Each row is compact: `:3000  project  [Next.js]  open  kill`. Click **kill** and it turns into **confirm?**, with a line naming the process, pid, port and folder. Click a row for its folder, command, address and URL, with *reveal* and *copy*.
- **Full view as a local web page.** Opening harbor from Applications or Spotlight, or choosing *Open harbor…* in the menu, opens `http://127.0.0.1:<port>/#<token>` in your browser. The page is served from inside the app. It shows ports grouped by project, category or flat list, in the same rows and with the same kill → confirm? flow as the menu.
- **Visible range**, as in Manfath. Ports outside a range (default 1024–65535) are hidden. You can also keep only dev servers, databases and runtimes, and show or hide macOS's own services. The menu and the page share these settings.
- **More of Manfath's options** in the gear menu:
  - **Refresh while open:** 1 s, 3 s, 10 s or manual.
  - **Menu bar badge:** count, dot or hidden. The default is hidden; with a badge on, the 60-second idle pass also counts ports.
  - **Hidden processes:** right-click a row to hide that process name, and unhide it here. The row menu also has *Copy URL*, *Copy PID* and *Reveal in Finder*.
- **Extras, kept apart from the ports.** There is one memory and swap line in the menu, a "This Mac" section on the page (RAM breakdown, biggest apps by real memory), and a warning when stuck (zombie) processes pile up. The menu bar icon turns green, orange or red with memory pressure and swap. It becomes a red warning triangle when one parent holds more than 50 zombies or the total passes 300.

## Build, install, run

Requires macOS 14+ and Xcode (or the Swift toolchain).

```sh
./build.sh      # swift build -c release, then assembles and ad-hoc signs build/harbor.app
./install.sh    # copies it to /Applications (falls back to ~/Applications if /Applications isn't writable)
open /Applications/harbor.app
```

- `build.sh` calls Xcode's toolchain binaries directly, because on some Macs the `/usr/bin` xcrun shims stall for minutes. It also draws the app icon from an SF Symbol.
- `install.sh` stops a running copy first. It removes an older copy in `~/Applications` so Spotlight doesn't show two. Set `INSTALL_DIR=…` to install somewhere else.
- The app is ad-hoc signed, not notarised. It is meant for this Mac.
- *Open at login* is in the menu's gear menu and on the page. It is off by default.

**Renaming:** change `APP_NAME` (and `BUNDLE_ID`) in `app.conf`, then run `./build.sh`. The app reads its name back from Info.plist, so menus, the page title and messages follow. `AppInfo.fallbackName` in `Sources/Harbor/AppInfo.swift` is only used when the binary runs outside the bundle.

## Why it's cheap

It never spawns `lsof`, `ps`, `top` or `netstat`. Everything is read in-process through system calls:

| What | How |
| --- | --- |
| Process list | `proc_listallpids` |
| Listening TCP ports | `proc_pidinfo(PROC_PIDLISTFDS)` per process, then `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)`. Keeps sockets in state `TSI_S_LISTEN`; the port comes from `insi_lport` (network byte order) |
| Folder, start time, name | `PROC_PIDVNODEPATHINFO` (cwd), `PROC_PIDTBSDINFO` (start time), `proc_pidpath`, `KERN_PROCARGS2` (command line) |
| Memory and CPU | `proc_pid_rusage` (`ri_phys_footprint`, the number Activity Monitor shows; CPU time converted with the Mach timebase) |
| RAM and swap | `host_statistics64(HOST_VM_INFO64)`, `sysctl vm.swapusage`, `kern.memorystatus_vm_pressure_level` |
| Memory pressure | `DispatchSource.makeMemoryPressureSource`, event-driven |
| Zombies | `proc_pidinfo(PROC_PIDT_SHORTBSDINFO)`. On current macOS `proc_pidinfo` answers ESRCH for zombies, so pids it can't see are checked with `sysctl(KERN_PROC_PID)` for `p_stat == SZOMB` |

When nothing is open, the only periodic work is a 60-second timer: one pass of short BSD info for zombie counts, plus swap and RAM numbers (about 0.3 ms). Ports, apps and CPU % are scanned only while they're on screen:

- **Menu open:** every 3 s while the panel is actually visible.
- **Page open:** when the page asks. It polls every 3 s while its tab is visible, and stops when hidden or closed. An idle listener costs nothing.

A full scan takes about 6 ms; the first scan after a quiet spell is slower while caches refill.

Measured on this Mac (16 GB, about 12 GB of swap in use), over 70 s each, with `ps -o time,%cpu,rss` and `footprint`:

| State | Average CPU | Memory (footprint / RSS) |
| --- | --- | --- |
| Nothing open | 0.01% | 17 MB / 45 MB |
| Page open, polling every 3 s | 0.41% | 19 MB / 61 MB |
| Menu open, refreshing every 3 s | 2.6% | 46 MB / 90 MB |

## The page's safety rules

The page server lives in the app (`Network.framework`):

- **Binding:** 127.0.0.1 only, on a random port.
- **Token:** a random per-launch token, sent in the URL fragment. Every `/api` call must carry it as an `X-Token` header.
- **Host check:** requests must carry `Host: 127.0.0.1:<port>`, which blocks DNS rebinding. A foreign `Origin` is refused.
- **Headers:** `Content-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'`, plus `nosniff`, `DENY` framing and `no-referrer`.
- **Rendering:** the page renders process names, paths and commands with `textContent` only.
- **Actions:** stop, quit, force and admin are POSTs, and only for pids the page was shown in its last refresh. Force is only allowed after a stop didn't work; the administrator route only after macOS refused.

## Stopping things

- **Stop:** sends SIGTERM and waits up to 3 s. For forked servers that share one socket (Flask's reloader, php-fpm, gunicorn), workers still holding the port get SIGTERM too. If the process is still alive, harbor offers **force kill** (SIGKILL).
- **GUI apps:** quit with `NSRunningApplication.terminate()`, so they can ask to save.
- **Root-owned processes** (for example an antivirus daemon): SIGTERM fails with EPERM, so harbor offers **admin password…**. That runs `do shell script "kill <pid>" with administrator privileges`. macOS shows its own password dialog, and harbor never sees the password. macOS's own processes (`/System`, `/usr/libexec`, …) are never offered.
- **Restarts:** if the process comes straight back under a new pid (launchd KeepAlive), harbor says: "It restarts itself. Use the app's own Quit or uninstall it."

## Limits

- **Other users' ports:** macOS only lets an app read its own user's file descriptors and memory. Listening ports of root-owned processes don't appear (the same as `lsof` without sudo). Their memory can't be measured either.
- **CPU %:** needs two samples, so it shows up about a second after the menu or page opens.

## Debug helpers

The binary has a few flags for testing (see `Sources/Harbor/DebugCLI.swift`). Set `HARBOR_DEBUG=1` to log scan-mode changes.

| Flag | What it does |
| --- | --- |
| `--dump` | prints what the app sees |
| `--bench N` | times the scans |
| `--serve` | starts the page server and prints its URL without opening a browser |
| `--no-open` | launches normally but doesn't open the page |
| `--demo-menu --snapshot PATH` | renders the menu into a PNG |
| `--test-stop PORT` | stops a server, but only one running from a temp folder |

## Layout

```
app.conf            name and bundle id (rename here)
build.sh            release build + harbor.app assembly + ad-hoc signing
install.sh          copy to /Applications
Sources/Harbor/
  System/           libproc, sysctl and Mach readers; the scanner
  Model/            Monitor (state, timers), Engine (stop/quit), Advice (verdicts)
  UI/               menu bar dropdown (SwiftUI MenuBarExtra)
  Web/              page server, JSON API, the page itself
```

`.build/` and `build/` are build output and are ignored by git.
