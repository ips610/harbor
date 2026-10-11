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
