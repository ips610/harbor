# The harbor command

Everything harbor does in its menu and on its page can be done from Terminal, and some things
only there. This page lists every command. The short version is in the README, under
"Command line".

Install the command from the gear menu (**Install the harbor command…**) or the page's
Settings strip. It puts a link to the app in `/usr/local/bin`, or `~/.local/bin`. If Terminal
says "command not found", add `export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc` and open a
new window.

`<x>` below is a port (`3000`), a `.localhost` or `.local` name (`storefront`,
`storefront.localhost`) or the name harbor's lists give it (`exams-portal`).

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Done. |
| 1 | It failed, or the app said no (a message says why). |
| 2 | The command line wasn't understood (the usage is printed). |
| 3 | Nothing listens there, or nothing by that name. |
| 4 | harbor won't stop that (macOS's own, harbor, Docker, another user's). |
| 5 | You said no. |
| 6 | The process changed while you were being asked. |

## Looking: no app needed

These run in the command's own process, with the app's scanner and rules. They never talk to
the running app and never read its session file.

### `harbor ls [--json] [--all]`

Every port, its `.localhost` name, the process, the folder, and what is shared. `--json` prints
the same as JSON, `--all` adds what the app hides by default (macOS services).

### `harbor scan [range] [--all] [--json]`

What is listening in a range of ports: `harbor scan 3000-3999`, or one port, or none for
every port. Exit 3 when nothing is in the range.

### `harbor check <x>`

Asks that server `GET /` once, as the page's status line does, with no cookie. Prints the
status and the page's title: `node on :3000: 200 · Storefront – Admin`, `302 → /login`, or
`not answering` (exit 1).

### `harbor watch [--every N]`

Prints the ports now, then a line when a server starts (`+`) or stops (`-`). `N` is 1 to 3600
seconds (5 by default). Ctrl-C ends it.

### `harbor kill <port> [-y] [--force] [--pid N]`

Stops what listens on a port. It asks first (`-y` skips the question), sends a normal quit and
waits 3 seconds, and `--force` then ends the process at once. When two processes share the
port it wants `--pid`. It never touches macOS's own processes, harbor, Docker or another
user's processes, and has no administrator path.

### `harbor open <x>`

Opens the server's `.localhost` address in the browser.

## Changing things: through the running app

These reach the app the way its page does: on its own port on this Mac, with the same private
session file (mode 0600, readable only by your account). The app answers with the same checks
as for a click. If harbor isn't running they say so and change nothing.

A password is never an argument, because it would stay in the shell's history and show up in
`ps`. Where one is needed it is typed at a prompt that doesn't echo, read as one line from
stdin with `--password-stdin`, or made by the app with `--random` and printed once.

### Network sharing

| Command | |
|---|---|
| `harbor shares` | What is on the network: name, address, whether it has a password, time left. |
| `harbor share <x> [--minutes 30\|60 \| --until-stopped] [--open \| --random \| --password-stdin]` | Puts it on the network as `name.local`. With no time given, the app's last choice. With no password option, a hidden prompt. `--open` means no password. |
| `harbor unshare <x>` | Takes it off the network. |
| `harbor extend <x> [30m\|1h\|2h…] [--public]` | Half an hour more for each 30 minutes, up to 8 hours. `--public` extends a public link. |
| `harbor password <x> [--random \| --password-stdin \| --remove]` | A new password for the project. Whoever was signed in signs in again. |

The app offers three durations: 30 minutes, 1 hour, or until stopped. `extend` is how to go
longer.

### Public links

| Command | |
|---|---|
| `harbor tunnels` | Public links, with time left. |
| `harbor tunnel <x> [--minutes 30\|60 \| --until-stopped]` | Starts a Cloudflare quick tunnel and prints the link when it is ready (up to a minute). Needs `cloudflared`. |
| `harbor tunnel stop <x>` | Ends it. |

### Servers that stopped

| Command | |
|---|---|
| `harbor stopped` | What harbor saw stop (the last 20, for a day, in memory only). |
| `harbor start <x> [-y]` | Starts one again. It prints the real program, arguments and folder, then asks. `-y` skips the question. Without a terminal and without `-y` nothing runs. |

### Names, groups and the icon

| Command | |
|---|---|
| `harbor rename <x> <name>` / `--reset` | The server's name in lists. |
| `harbor groups` | Groups made by hand, with how many servers are in each. |
| `harbor group <x> <title>` / `--auto` | Puts it in a group (made when new), or back on its automatic card. |
| `harbor group rename <title> <new title>` | Renames a group. |
| `harbor group delete <title>` | Deletes a group; its servers go back on their own cards. |
| `harbor menubar [on\|off]` | Shows or hides harbor's menu bar icon. With no word, says which. |

Groups and names are saved by project folder and port, so a server started again goes back
into its group. They change which card a row sits on and what lists call it; the `.localhost`
and `.local` names, passwords and the main server are not touched.

## Working from Terminal only

```
harbor menubar off     # no icon in the menu bar
```

harbor keeps running (launchd starts it when something connects), so the commands above keep
working. The page is still at `http://harbor.localhost:8470`. Turn the Dock icon off in the
page's Settings too if you want no icon at all. `harbor menubar on` brings the icon back.
