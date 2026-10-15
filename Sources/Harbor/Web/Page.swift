// The harbor page, served by WebServer at http://harbor.localhost:8470/ (or the port it moved to).
// Every value from the app is rendered with textContent; nothing is parsed as HTML.
enum Page {
    /// The page with the session script and the app's name filled in (see AppInfo).
    static let html = fill(template)

    /// Shared with PageLooks, so both pages sign in the same way.
    static func fill(_ template: String) -> String {
        template.replacingOccurrences(of: "__SESSION__", with: sessionScript)
            .replacingOccurrences(of: "__QR__", with: qrScript)
            .replacingOccurrences(of: "__APP__", with: AppInfo.name)
            .replacingOccurrences(of: "__app__", with: AppInfo.name.lowercased())
    }

    /// A page with the Appearance setting already on <html> (so the first paint
    /// is right) and the CSP nonce filled into its inline <script>. `crossNav`
    /// marks a visit that came from another website: the page then won't ask
    /// harbor to open a tab. Nothing secret ever goes into the page.
    static func themed(_ page: String, _ appearance: String, nonce: String, crossNav: Bool = false) -> String {
        page.replacingOccurrences(of: "data-theme=\"__theme__\"",
                                  with: "data-theme=\"\(appearance)\"" + (crossNav ? " data-nav=\"cross\"" : ""))
            .replacingOccurrences(of: "__NONCE__", with: nonce)
    }

    /// How a tab signs in, for both pages. Each page supplies `poll()` and shows
    /// the lines `signedOut()` returns.
    static let sessionScript = #"""
// ---------- session ----------
// A tab is signed in by two things together: an HttpOnly cookie, and this key in
// localStorage. A cookie alone isn't tied to a port on localhost; localStorage is,
// so another program on a different port of this name can be sent the cookie but
// never the key. Every API call carries both; POSTs add X-Harbor.
const KEY = '__app__.key';
let key = null;
try { key = localStorage.getItem(KEY); } catch (e) {}
function setKey(value) {
  key = value || null;
  try { if (key) localStorage.setItem(KEY, key); else localStorage.removeItem(KEY); } catch (e) {}
}
async function api(path, body) {
  const opts = { credentials: 'same-origin', cache: 'no-store', headers: {} };
  if (key) opts.headers['X-Harbor-Key'] = key;
  if (body) { opts.method = 'POST'; opts.headers['Content-Type'] = 'application/json'; opts.headers['X-Harbor'] = '1'; opts.body = JSON.stringify(body); }
  const reply = await fetch(path, opts);
  const data = await reply.json().catch(() => ({}));
  if (!reply.ok) throw new Error(data.error || ('HTTP ' + reply.status));
  return data;
}
// __APP__ opened this tab with a one-time code in the address: trade it for the
// cookie and the key, then clean the address.
async function redeem() {
  const url = new URL(location.href), code = url.searchParams.get('k');
  if (!code) return;
  try { setKey((await api('/api/login', { code })).key); } catch (e) {}
  url.searchParams.delete('k');
  history.replaceState(null, '', url.pathname + url.search);
}
// Signed out: ask __APP__ to open a signed-in tab. It opens the tab itself, so the
// link only reaches this Mac's own browser. Asked once per page load, only from
// poll() (so only while the tab is visible), and never for a visit that came from
// another website. Resolves to the lines to show.
const QUIT_TEXT = '__APP__ was quit. Type ' + location.host + ' in the address bar to start it again.';
let asked = null;
function signedOut() {
  setKey(null);
  if (!asked) asked = (async () => {
    if (document.documentElement.dataset.nav === 'cross') return ['Open __APP__ from the menu bar.'];
    try {
      if ((await api('/api/invite', {})).quit) return [QUIT_TEXT];
    } catch (e) { return ['Open __APP__ from the menu bar.']; }
    return ['__APP__ is opening in a new tab. You can close this one.',
      'If nothing opens, it opened in your default browser, or click Open __APP__ in the menu bar.'];
  })();
  return asked;
}
// The new tab signed in and stored the key: this tab can start working too.
window.addEventListener('storage', (e) => {
  if (e.key === KEY && e.newValue) { key = e.newValue; asked = null; poll(); }
});
"""#

    /// How both pages draw a QR code: harbor's style (the same as QR.image in the app), as SVG
    /// built node by node from the rows /api/qr returns. Those rows have no quiet zone.
    static let qrScript = #"""
// ---------- QR codes ----------
// A white card, soft squares, the three corner eyes as shapes, and the wave mark in the middle
// (the code is made at correction level H, so the mark may cover some of it). Always dark on
// white, in dark mode too: inverted codes fail on some phones. 4 px per module.
function qrSvg(rows, label) {
  const NS = 'http://www.w3.org/2000/svg';
  const make = (tag, attrs) => { const n = document.createElementNS(NS, tag); for (const k in attrs) n.setAttribute(k, attrs[k]); return n; };
  const N = rows.length, Q = 4, T = N + Q * 2, ink = '#0b0b0c';
  // The square cleared for the mark: odd, about 24% of the width (7 of 29, 11 of 49).
  let hole = Math.floor(N * 0.245);
  if (hole % 2 === 0) hole -= 1;
  const lo = (N - hole) / 2, hi = lo + hole;
  const eye = (x, y) => (x < 7 && y < 7) || (x >= N - 7 && y < 7) || (x < 7 && y >= N - 7);
  const svg = make('svg', { viewBox: `0 0 ${T} ${T}`, width: T * 4, height: T * 4, role: 'img', 'aria-label': label });
  svg.append(make('rect', { width: T, height: T, rx: T * 0.07, fill: '#fff' }));
  // Every module is a 0.88 square with 0.3 corners; all of them in one path.
  let d = '';
  for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) {
    if (rows[y][x] !== '1' || eye(x, y) || (x >= lo && x < hi && y >= lo && y < hi)) continue;
    d += `M${x + Q + 0.36} ${y + Q + 0.06}h.28a.3.3 0 0 1 .3.3v.28a.3.3 0 0 1-.3.3h-.28a.3.3 0 0 1-.3-.3v-.28a.3.3 0 0 1 .3-.3z`;
  }
  svg.append(make('path', { d, fill: ink }));
  for (const [ex, ey] of [[0, 0], [N - 7, 0], [0, N - 7]]) {
    svg.append(make('rect', { x: ex + Q + 0.5, y: ey + Q + 0.5, width: 6, height: 6, rx: 1.9, fill: 'none', stroke: ink, 'stroke-width': 1 }));
    svg.append(make('rect', { x: ex + Q + 2, y: ey + Q + 2, width: 3, height: 3, rx: 1, fill: ink }));
  }
  // The app's tile, one module smaller than its hole, in the tab icon's 64-unit square.
  const mark = make('g', { transform: `translate(${lo + Q + 0.5} ${lo + Q + 0.5}) scale(${(hole - 1) / 64})` });
  mark.append(make('rect', { width: 64, height: 64, rx: 14, fill: '#16171c' }));
  for (const wave of __WAVES__) mark.append(make('path', { d: wave, fill: 'none', stroke: '#a7b4ff', 'stroke-width': 6, 'stroke-linecap': 'round' }));
  svg.append(mark);
  return svg;
}
"""#.replacingOccurrences(of: "__WAVES__", with: "[" + waves.map { "'\($0)'" }.joined(separator: ", ") + "]")

    /// Dark-mode CSS: under macOS dark mode unless the page is set to Light, and
    /// always when it's set to Dark. `scope` narrows it, e.g. "body.look-a".
    static func dark(_ decls: String, _ scope: String = "") -> String {
        let s = scope.isEmpty ? "" : " " + scope
        return """
        @media (prefers-color-scheme: dark) { :root:not([data-theme="light"])\(s) { \(decls) } }
          :root[data-theme="dark"]\(s) { \(decls) }
        """
    }

    /// harbor's mark, the header's two waves, on an ink tile that reads on light and
    /// dark tab strips. Served as /favicon.svg; the app icon and the menu bar glyph
    /// draw the same paths (WaveMark). A flat fill, the same build as headroom's icon,
    /// which Safari does show.
    static let icon = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
    <rect width="64" height="64" rx="14" fill="#16171c"/>
    <g fill="none" stroke="#a7b4ff" stroke-width="6" stroke-linecap="round">\(waves.map { "<path d=\"\($0)\"/>" }.joined())</g>
    </svg>
    """

    /// The mark's two waves as SVG path data, in the 64-unit square (WaveMark's curves). The
    /// tab icon above and the mark in the middle of a QR code both use them.
    static let waves = ["M11 25c5-4.8 9-4.8 14 0s9 4.8 14 0 9-4.8 14 0", "M11 39c5-4.8 9-4.8 14 0s9 4.8 14 0 9-4.8 14 0"]

    private static let darkTokens = """
      color-scheme: dark;
          --ink: #0b0b0c; --on-ink: #f3f3f1; --on-ink-2: #a2a5ac; --on-ink-3: #8a8d95; --ink-line: #24252a;
          --signal: #a7b4ff; --live: #46d39a; --tick: #2c2e33; --hero-warn: #f5b25c;
          --bg: #0e0e10; --panel: #16161a; --panel-2: #1d1d22; --line: #27272d;
          --text: #f2f2f0; --text-2: #c7c9cf; --muted: #8d9099;
          --danger: #ff5d4d; --danger-soft: #2a1513; --warn: #f2a54a; --warn-soft: #261c10;
          --focus: #a7b4ff; --c-ports: #a7b4ff; --c-mac: #46d39a; --shared: #46d39a; --shared-ink: #0e0e10;
          --open-bg: #1f3352; --open-ink: #a9c8ff; --share-bg: #173b2e; --share-ink: #86e3bb;
          --seg-1: #3987e5; --seg-2: #d95926; --seg-3: #199e70; --seg-4: #c98500; --seg-free: #2a2a2f;
          --seq: #3987e5; --seq-track: #1c2636;
          --mac-tint: #1e1e23; --mac-stripe: #8e8e93; --mac-pill-bg: #3a3a3e; --mac-pill-ink: #f2f2f7;
    """

    private static let template = #"""
<!doctype html>
<html lang="en" data-theme="__theme__">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="light dark">
<title>__app__</title>
<link rel="icon" type="image/png" sizes="32x32" href="/favicon-32.png?v=4">
<link rel="icon" type="image/svg+xml" href="/favicon.svg?v=4">
<link rel="apple-touch-icon" href="/apple-touch-icon.png?v=4">
<style>
  /* Light tokens here; dark ones in Page.darkTokens, applied by macOS dark mode
     or by the Appearance setting (data-theme on <html>, set by the server). */
  :root {
    color-scheme: light dark;
    --ink: #f3f3ef;
    --on-ink: #0b0b0c;
    --on-ink-2: #45474d;
    --on-ink-3: #62656d;
    --ink-line: #e0e0da;
    --signal: #3d4bd1;
    --live: #10915f;
    --tick: #d8d8d1;
    --hero-warn: #8f4c00;
    --bg: #ffffff;
    --panel: #f6f6f4;
    --panel-2: #efefec;
    --line: #e5e5e1;
    --text: #0b0b0c;
    --text-2: #45474d;
    --muted: #65686f;
    --danger: #c3301f;
    --danger-soft: #fbeae8;
    --warn: #a35a00;
    --warn-soft: #fbf1e3;
    --focus: #4a63f5;
    --mac-tint: #eeeef1; --mac-stripe: #8e8e93; --mac-pill-bg: #e3e3e8; --mac-pill-ink: #1d1d1f;
    --c-ports: #4b5bdc;
    --c-mac: #0e7d5d;
    --shared: #0f7f5f;
    --shared-ink: #ffffff;
    --open-bg: #dbe7fb;
    --open-ink: #0a4fb0;
    --share-bg: #d4f0e4;
    --share-ink: #0b6b4b;
    --f-display: -apple-system, BlinkMacSystemFont, "SF Pro Display", system-ui, sans-serif;
    --f-body: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
    --f-mono: ui-monospace, "SF Mono", SFMono-Regular, Menlo, monospace;
    --gutter: clamp(16px, 3.2vw, 36px);
    --ease: cubic-bezier(.2, .7, .1, 1);
  }
  :root[data-theme="light"] { color-scheme: light; }
  \#(dark(darkTokens))
  *, *::before, *::after { box-sizing: border-box; }
  html { -webkit-text-size-adjust: 100%; }
  body {
    margin: 0; min-height: 100vh; overflow-x: clip; background: var(--bg); color: var(--text);
    font: 15px/1.5 var(--f-body); -webkit-font-smoothing: antialiased; padding-bottom: 110px;
  }
  h1, h2, h3, p, ul { margin: 0; }
  ul { padding: 0; list-style: none; }
  button, input { font: inherit; color: inherit; }
  [hidden] { display: none !important; }
  :focus-visible { outline: 2px solid var(--focus); outline-offset: 2px; border-radius: 6px; }
  .wrap { max-width: 1400px; margin: 0 auto; padding-inline: var(--gutter); }
  .mono { font-family: var(--f-mono); font-size: 11px; letter-spacing: .08em; text-transform: uppercase; line-height: 1.4; }
  .display { font-family: var(--f-display); font-weight: 800; letter-spacing: -.045em; line-height: .9; }
  .ico { width: 1em; height: 1em; flex: none; vertical-align: -.125em; }

  /* ---------- ink hero ---------- */
  .top { background: var(--ink); color: var(--on-ink); --focus: var(--signal); }
  .nav { display: flex; align-items: center; justify-content: space-between; gap: 16px; padding-block: 18px; }
  .logo { display: inline-flex; align-items: center; gap: 10px; font: 800 19px/1 var(--f-display); letter-spacing: -.04em; }
  .logo svg { width: 26px; height: 18px; color: var(--signal); }
  .brand { display: inline-flex; align-items: center; gap: 12px; }
  .gh { display: inline-flex; padding: 7px; margin: -7px; border-radius: 999px; color: var(--on-ink-2); transition: color .2s; }
  .gh:hover { color: var(--on-ink); }
  .gh svg { width: 18px; height: 18px; fill: currentColor; }
  .nav-end { display: flex; align-items: center; gap: 18px; }
  .nav .seg { background: var(--ink-line); }
  .nav .seg button { color: var(--on-ink-2); }
  .nav .seg button[aria-pressed="true"] { background: var(--bg); color: var(--text); }
  .nav-meta { color: var(--on-ink-3); }
  .strip {
    display: flex; flex-wrap: wrap; justify-content: space-between; gap: 6px 24px;
    padding-block: 10px; border-block: 1px solid var(--ink-line); color: var(--on-ink-2);
  }
  .strip span { display: inline-flex; align-items: center; gap: 8px; }
  .dot { width: 7px; height: 7px; border-radius: 50%; background: var(--live); flex: none; display: inline-block; }
  .dot.off { background: var(--on-ink-3); }
  .hero {
    display: grid; grid-template-columns: auto minmax(0, 40ch); justify-content: space-between; align-items: end;
    gap: 20px 48px; padding-top: clamp(28px, 5vw, 60px);
  }
  .hero-num { font-size: clamp(104px, 17vw, 220px); display: flex; align-items: flex-start; gap: .06em; }
  .hero-num small { font-size: .2em; letter-spacing: -.02em; color: var(--signal); margin-top: .18em; line-height: 1.1; font-weight: 700; }
  .hero-side { display: grid; gap: 10px; padding-bottom: 12px; }
  .hero-label { color: var(--signal); }
  .hero-lede { font-size: clamp(16px, 1.4vw, 19px); line-height: 1.38; font-weight: 500; }
  .hero-lede .warn { color: var(--hero-warn); }
  .map { margin-top: clamp(26px, 4vw, 44px); }
  .ticks { display: flex; align-items: flex-end; gap: 3px; height: 46px; }
  .ticks i {
    flex: 1 1 0; min-width: 0; height: 22%; border-radius: 1px; background: var(--tick);
    transition: height .45s var(--ease), background-color .45s;
  }
  .ticks i.on { height: 100%; }
  .axis { position: relative; height: 26px; color: var(--on-ink-3); }
  .axis span { position: absolute; top: 8px; transform: translateX(-50%); white-space: nowrap; }
  .axis span:first-child { transform: none; }
  .legend { display: flex; flex-wrap: wrap; gap: 6px 22px; padding-block: 4px 26px; color: var(--on-ink-2); }
  .legend li { display: inline-flex; align-items: center; gap: 8px; }
  .legend b { color: var(--on-ink); font-weight: 600; }
  .sw { width: 8px; height: 8px; border-radius: 1px; display: inline-block; }

  /* ---------- banners ---------- */
  .alarm { background: #1a0907; color: #ffd9d4; border-bottom: 1px solid #3a1512; }
  .alarm .wrap { display: flex; align-items: center; gap: 16px; padding-block: 14px; flex-wrap: wrap; }
  .alarm p { flex: 1 1 320px; font-weight: 500; }
  .alarm b { color: #fff; }
  .notice { background: var(--warn-soft); color: var(--text); border-bottom: 1px solid var(--line); }
  .notice .wrap { display: flex; align-items: center; gap: 12px; padding-block: 10px; }
  .notice p { flex: 1; font-size: 14px; }
  .notice.update { background: var(--open-bg); }
  .offline { background: var(--panel-2); border-bottom: 1px solid var(--line); }
  .offline .wrap { padding-block: 12px; font-size: 14px; color: var(--text-2); }

  /* ---------- sections ---------- */
  section { padding-top: clamp(36px, 5vw, 64px); }
  .sec-head { display: flex; align-items: flex-end; justify-content: space-between; gap: 16px 24px; flex-wrap: wrap; margin-bottom: 18px; }
  .sec-title { display: flex; align-items: flex-start; gap: 12px; }
  .sec-num { font: 600 13px/1 var(--f-mono); color: var(--sec); letter-spacing: .04em; margin-top: 5px; }
  .sec-title h2 { font-size: clamp(34px, 4.4vw, 52px); }
  .sec-sub { color: var(--muted); font-size: 14px; margin-top: 8px; }
  .controls { display: flex; align-items: center; gap: 14px; flex-wrap: wrap; }
  .seg { display: inline-flex; background: var(--panel-2); border-radius: 999px; padding: 3px; }
  .seg button { border: 0; background: transparent; padding: 5px 14px; border-radius: 999px; font-size: 13px; font-weight: 600; cursor: pointer; color: var(--muted); }
  .seg button[aria-pressed="true"] { background: var(--bg); color: var(--text); box-shadow: 0 1px 2px #0000001f; }
  .seg.small button { padding: 4px 10px; font-size: 12px; }
  .check { display: inline-flex; align-items: center; gap: 8px; font-size: 13px; color: var(--text-2); cursor: pointer; }
  .check input { width: 16px; height: 16px; margin: 0; accent-color: var(--c-ports); }

  /* ---------- port cards ---------- */
  .cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(min(100%, 600px), 1fr)); gap: 16px; align-items: start; }
  .card { background: var(--panel); border-radius: 14px; overflow: hidden; border-top: 3px solid var(--pc, var(--c-ports)); }
  .card-head { display: flex; align-items: flex-start; justify-content: space-between; gap: 12px; padding: 16px 18px 10px; }
  .card-title { min-width: 0; }
  .card-title h3 { font: 750 21px/1.15 var(--f-display); letter-spacing: -.025em; overflow-wrap: anywhere; }
  .card-path { color: var(--muted); margin-top: 4px; overflow-wrap: anywhere; letter-spacing: .02em; text-transform: none; font-size: 11.5px; }
  .chips { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 8px; }
  .chip { font: 600 11px/1 var(--f-body); padding: 4px 7px; border-radius: 5px; background: var(--panel-2); color: var(--text-2); }
  .chip.warn { background: var(--warn-soft); color: var(--warn); }
  /* Manfath-style rows, scaled up: port · name · tags … open copy kill */
  .rows > li { border-top: 1px solid var(--line); }
  .prow { display: grid; grid-template-columns: minmax(0, 1fr) auto; align-items: center; gap: 8px 14px; padding: 11px 18px; cursor: pointer; }
  .prow:hover, .rows > li.open .prow { background: var(--panel-2); }
  .pmain { display: grid; grid-template-columns: 96px minmax(0, 1fr); align-items: center; column-gap: 14px; min-width: 0; }
  .pport { font: 600 22px/1 var(--f-mono); letter-spacing: -.02em; }
  .ptext { min-width: 0; }
  .ptitle { display: flex; align-items: center; gap: 7px; font-weight: 600; font-size: 15px; min-width: 0; }
  .ptitle .t { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .tag { font: 600 11px/1 var(--f-body); padding: 3px 6px; border-radius: 5px; border: 1px solid var(--line); color: var(--muted); white-space: nowrap; }
  .tag.warn { border-color: transparent; background: var(--warn-soft); color: var(--warn); }
  .tag.macos { border-color: transparent; background: var(--mac-pill-bg); color: var(--mac-pill-ink); display: inline-flex; align-items: center; gap: 4px; }
  .tag.macos svg, .card-badge svg { width: 12px; height: 12px; flex: none; }
  .card.mac-svc { border-top-color: var(--mac-stripe); }
  .card.mac-svc .card-head { background: var(--mac-tint); }
  .card-badge { display: inline-flex; align-items: center; gap: 6px; margin-top: 6px; padding: 4px 9px 4px 7px; border-radius: 999px;
    background: var(--mac-pill-bg); color: var(--mac-pill-ink); font: 600 12px/1 var(--f-body); }
  .netaddr { font: inherit; border: 0; background: none; padding: 0; color: var(--open-ink); cursor: copy;
    text-decoration: underline dotted; text-underline-offset: 3px; }
  .netaddr:hover { text-decoration-style: solid; }
  .netaddr.local { color: var(--muted); cursor: inherit; text-decoration: none; }
  .tag.shared { border-color: transparent; background: var(--shared); color: var(--shared-ink); }
  .psub { color: var(--muted); font-size: 13px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  /* The row's name, on a line of its own under the row (inside it, so it shares the hover and the click). */
  .pname { grid-column: 1 / -1; margin-top: -5px; padding-left: 110px; font: 12.5px/1.5 var(--f-mono); color: var(--muted);
    white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .pname a { color: var(--open-ink); text-decoration: none; }
  /* What the server answered when harbor last asked it: its status, and its page's title. */
  .pserved { margin-top: -6px; color: var(--text-2); }
  .left { color: var(--text-2); font-variant-numeric: tabular-nums; }
  /* Servers that stopped, with a way to start each again. */
  #stopped { margin-top: 18px; }
  #stopped:empty { display: none; }
  .card.was { --pc: var(--muted); }
  .card.was .prow, .card.was .prow:hover { cursor: default; background: none; }
  .card.was .pcmd { grid-column: 1 / -1; margin-top: -5px; padding-left: 110px; font: 12.5px/1.5 var(--f-mono); color: var(--muted); overflow-wrap: anywhere; }
  .bell { display: inline-flex; align-items: center; gap: 6px; }
  .bell svg { width: 12px; height: 12px; }
  .pname a:hover { text-decoration: underline; text-underline-offset: 3px; }
  .card-acts { display: flex; flex: none; }
  .pacts { display: flex; gap: 6px; align-items: center; }
  .pl {
    font: 500 12.5px/1 var(--f-body); padding: 7px 12px; border-radius: 999px; border: 0; background: var(--panel-2);
    color: var(--text-2); cursor: pointer; text-decoration: none; white-space: nowrap; transition: background-color .15s, color .15s;
  }
  .card .pl, .group .pl { background: var(--bg); }
  .pl:hover { background: var(--line); color: var(--text); }
  .pl.kill:hover { background: var(--danger-soft); color: var(--danger); }
  .card .pl.open, .group .pl.open, .pl.open { background: var(--open-bg); color: var(--open-ink); }
  .card .pl.share, .group .pl.share, .pl.share { background: var(--share-bg); color: var(--share-ink); }
  .pl.open:hover, .pl.share:hover { filter: brightness(.96); }
  .pl.confirm, .pl.force { background: var(--danger); color: #fff; }
  .pl.confirm:hover, .pl.force:hover { background: var(--danger); color: #fff; filter: brightness(1.08); }
  .pl.admin { background: var(--text); color: var(--bg); }
  .pl.admin:hover { background: var(--text); color: var(--bg); }
  .pline { padding: 0 18px 12px 128px; font-size: 13px; color: var(--danger); }
  .pline.share { color: var(--warn); }
  .pline code, .ptunnel code { font: 12px var(--f-mono); background: var(--panel-2); padding: 2px 6px; border-radius: 5px; color: var(--text-2); }
  .pl.go { background: var(--shared); color: var(--shared-ink); }
  .pl.icon { padding: 5px 8px; display: inline-flex; align-items: center; }
  .pl.icon.on { background: var(--open-bg); color: var(--open-ink); }
  .ptitle { flex-wrap: wrap; row-gap: 3px; }
  .pl.go:hover { background: var(--shared); color: var(--shared-ink); filter: brightness(1.08); }
  .ptunnel { padding: 0 18px 12px 128px; display: flex; flex-wrap: wrap; align-items: center; gap: 8px; font-size: 13px; color: var(--text-2); }
  .ptunnel a { font: 12.5px/1.4 var(--f-mono); color: var(--c-mac); overflow-wrap: anywhere; }
  /* A code sits in the middle of the details, and so do two: one centre line, however many there are. */
  .qr { margin: 0 18px 12px 128px; display: flex; justify-content: center; }
  .qr svg { display: block; }
  /* Two codes: side by side, each under what it is and its link; one under the other when there's no room. */
  .qrs { display: flex; flex-wrap: wrap; justify-content: center; gap: 4px 28px; padding: 0 18px 0 128px; }
  .qrc { margin: 0; max-width: 100%; display: flex; flex-direction: column; align-items: center; }
  .qrc figcaption { display: flex; flex-wrap: wrap; align-items: center; justify-content: center; gap: 6px 8px; margin-bottom: 8px; font-size: 13px; color: var(--text-2); text-align: center; }
  .qrc figcaption a { font: 12.5px/1.4 var(--f-mono); color: var(--c-mac); overflow-wrap: anywhere; }
  .qrc .qr { margin: 0 0 12px; }
  .pline.info { color: var(--text-2); }
  .pdetails { display: grid; grid-template-columns: 6.5em minmax(0, 1fr) auto; gap: 7px 12px; padding: 2px 18px 14px 128px; align-items: baseline; margin: 0; }
  .pdetails dt { color: var(--muted); font: 11px/1.4 var(--f-mono); text-transform: uppercase; letter-spacing: .06em; }
  .pdetails dd { margin: 0; font: 12.5px/1.45 var(--f-mono); color: var(--text-2); overflow-wrap: anywhere; }
  .group { background: var(--panel); border-radius: 14px; overflow: hidden; }
  .group-title { display: flex; gap: 8px; align-items: baseline; padding: 14px 18px 8px; color: var(--muted); }
  .group-title b { color: var(--text-2); font-weight: 600; }
  .stack-list { display: grid; gap: 16px; }
  .range { display: inline-flex; align-items: center; gap: 6px; font-size: 13px; color: var(--text-2); }
  .range input { width: 6.2em; padding: 5px 8px; border-radius: 8px; border: 1px solid var(--line); background: var(--bg); font: 13px var(--f-mono); }
  .btn {
    display: inline-flex; align-items: center; justify-content: center; gap: 6px; min-height: 30px; padding: 0 12px;
    border-radius: 999px; border: 1px solid var(--line); background: var(--bg); color: var(--text);
    font: 600 12.5px/1 var(--f-body); cursor: pointer; text-decoration: none; white-space: nowrap;
    transition: background-color .15s, border-color .15s, transform .15s var(--ease);
  }
  .btn:hover { border-color: var(--muted); }
  .btn:active { transform: scale(.97); }
  .btn.stop:hover { border-color: var(--danger); color: var(--danger); }
  .btn.quiet { border-color: transparent; background: transparent; color: var(--muted); padding: 0 8px; }
  .btn.quiet:hover { color: var(--text); }
  .btn[disabled] { opacity: .45; cursor: default; }
  .busy { display: inline-flex; align-items: center; gap: 8px; color: var(--muted); font-size: 12.5px; padding-inline: 8px; }
  .spinner { width: 14px; height: 14px; border-radius: 50%; border: 2px solid var(--line); border-top-color: var(--text); animation: spin .8s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
  .hint { grid-column: 2 / -1; color: var(--muted); font-size: 12.5px; }
  .empty { background: var(--panel); border-radius: 14px; padding: 40px 24px; text-align: center; color: var(--muted); }
  .empty b { display: block; color: var(--text); font: 700 20px/1.2 var(--f-display); letter-spacing: -.02em; margin-bottom: 6px; }
  .hidden-note { color: var(--muted); font-size: 13px; margin-top: 14px; }

  /* ---------- this mac ----------
     Colour by job (validated with the dataviz validator, light and dark):
     the RAM bar is a composition, four categorical slots in fixed order plus a
     neutral "free" track; app bars are magnitude, one sequential hue; pressure
     is a status, always with an icon and a label. */
  :root {
    --seg-1: #2a78d6; --seg-2: #eb6834; --seg-3: #1baf7a; --seg-4: #eda100; --seg-free: #e2e2de;
    --seq: #2a78d6; --seq-track: #dfe9f6;
    --good: #0ca30c; --warning: #fab219; --critical: #d03b3b;
  }
  .mac { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1.1fr); gap: 16px; align-items: stretch; }
  .panel { background: var(--panel); border-radius: 14px; padding: 18px 20px; display: grid; gap: 14px; align-content: start; }
  .panel h3 { font: 650 15px/1.3 var(--f-body); }
  .panel .sub { color: var(--muted); font-size: 13px; margin-top: 2px; }
  .mac-head { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
  .status { display: inline-flex; align-items: center; gap: 7px; padding: 4px 10px 4px 8px; border-radius: 999px; background: var(--panel-2); font-size: 12.5px; font-weight: 600; color: var(--text); white-space: nowrap; }
  .status i { width: 10px; height: 10px; display: inline-block; }
  .status.good i { background: var(--good); border-radius: 50%; }
  .status.warning i { background: var(--warning); clip-path: polygon(50% 0, 100% 100%, 0 100%); }
  .status.critical i { background: var(--critical); border-radius: 2px; }
  .verdict { font-size: 14px; color: var(--text-2); }
  .mac-stat { font-size: 13.5px; color: var(--muted); }
  .mac-stat b { font: 650 26px/1.1 var(--f-body); color: var(--text); letter-spacing: -.01em; margin-right: 4px; }
  .comp { display: flex; gap: 2px; height: 14px; }
  .comp i { display: block; min-width: 3px; }
  .comp i:first-child { border-radius: 4px 0 0 4px; }
  .comp i:last-child { border-radius: 0 4px 4px 0; }
  .legend-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(140px, 1fr)); gap: 6px 14px; font-size: 12.5px; }
  .legend-grid span { display: flex; align-items: center; gap: 7px; color: var(--text-2); }
  .legend-grid b { margin-left: auto; color: var(--text); font-weight: 600; font-variant-numeric: tabular-nums; }
  .sw { width: 10px; height: 10px; border-radius: 3px; display: inline-block; flex: none; }
  .meter-head { display: flex; justify-content: space-between; gap: 10px; font-size: 13px; color: var(--text-2); }
  .meter-head b { color: var(--text); font-weight: 600; font-variant-numeric: tabular-nums; }
  .meter { height: 8px; border-radius: 4px; background: var(--seq-track); overflow: hidden; margin-top: 6px; }
  .meter i { display: block; height: 100%; border-radius: 0 4px 4px 0; background: var(--seq); }
  .meter.heavy i { background: var(--warning); }
  .spark { display: flex; align-items: center; gap: 10px; color: var(--muted); font-size: 12px; margin-top: 8px; }
  .spark svg { flex: 1; height: 28px; overflow: visible; }
  .action { font-size: 13.5px; color: var(--text); padding-top: 12px; border-top: 1px solid var(--line); }
  .apps { display: grid; }
  .apps li { display: grid; grid-template-columns: minmax(0, 9em) minmax(0, 1fr) 4.6em 7em; gap: 12px; align-items: center; min-height: 34px; }
  .apps li + li { border-top: 1px solid var(--line); }
  .apps .nm { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-weight: 600; font-size: 14px; }
  .apps .nm small { display: block; font-weight: 400; color: var(--muted); font-size: 11.5px; }
  .apps .track { height: 10px; border-radius: 0 4px 4px 0; background: var(--seq-track); }
  .apps .fill { display: block; height: 100%; border-radius: 0 4px 4px 0; background: var(--seq); }
  .apps .val { font: 600 13px/1 var(--f-body); font-variant-numeric: tabular-nums; text-align: right; }
  .apps .slot { display: flex; justify-content: flex-end; }
  .settings { display: flex; flex-wrap: wrap; align-items: center; gap: 10px 22px; margin-top: 28px; padding: 14px 18px; border-radius: 12px; background: var(--panel); font-size: 13px; color: var(--muted); }
  .settings b { color: var(--text); font-weight: 600; }

  /* ---------- floating pill ---------- */
  .pill {
    position: fixed; left: 50%; bottom: max(18px, env(safe-area-inset-bottom)); transform: translateX(-50%);
    display: flex; align-items: center; gap: 12px; padding: 7px 8px 7px 16px; border-radius: 999px;
    background: #111114f2; color: var(--on-ink); box-shadow: 0 10px 30px #00000038, inset 0 0 0 1px #ffffff14;
    width: min(620px, calc(100vw - 24px)); z-index: 5;
    /* The pill stays dark ink in both themes. */
    --on-ink: #f3f3f1; --on-ink-2: #a2a5ac; --on-ink-3: #8a8d95; --signal: #a7b4ff; --live: #46d39a; --focus: #a7b4ff;
  }
  .pill .status { display: inline-flex; align-items: center; gap: 8px; color: var(--on-ink-2); white-space: nowrap; background: #ffffff14; }
  .pill input {
    flex: 1; min-width: 0; background: #ffffff12; border: 1px solid #ffffff1c; border-radius: 999px;
    padding: 8px 14px; color: var(--on-ink); outline: none; font-size: 14px;
  }
  .pill input::placeholder { color: var(--on-ink-3); }
  .pill input:focus { border-color: var(--signal); }
  .pill-refresh { background: #ffffff14; border: 1px solid #ffffff26; color: var(--on-ink); border-radius: 999px; padding: 8px 14px; font: 600 13px/1 var(--f-body); cursor: pointer; white-space: nowrap; }
  .pill-refresh:hover { background: #ffffff24; }
  .toast {
    position: fixed; left: 50%; transform: translateX(-50%); bottom: calc(max(18px, env(safe-area-inset-bottom)) + 62px);
    background: var(--text); color: var(--bg); padding: 9px 16px; border-radius: 10px; font-size: 14px; z-index: 6;
    max-width: min(560px, calc(100vw - 24px)); box-shadow: 0 8px 24px #0000002e;
  }

  /* ---------- dialog: normal size, plain ---------- */
  dialog {
    border: 0; border-radius: 14px; padding: 22px 22px 18px; width: min(420px, calc(100vw - 32px));
    background: var(--bg); color: var(--text); box-shadow: 0 24px 60px #0000004d;
  }
  dialog::backdrop { background: #0000004d; }
  dialog h3 { font: 650 17px/1.3 var(--f-body); }
  dialog p { color: var(--text-2); font-size: 14px; margin-top: 8px; overflow-wrap: anywhere; white-space: pre-line; }
  dialog input { width: 100%; margin-top: 14px; padding: 8px 10px; border-radius: 8px; border: 1px solid var(--line); background: var(--bg); font: 14px var(--f-mono); }
  .dlg-actions { display: flex; justify-content: flex-end; gap: 8px; margin-top: 20px; }
  .dlg-actions .btn { min-height: 34px; padding: 0 16px; font-size: 13.5px; }
  .btn.primary { background: var(--text); color: var(--bg); border-color: var(--text); }
  .btn.danger { background: var(--danger); color: #fff; border-color: var(--danger); }

  @media (max-width: 760px) {
    .hero { grid-template-columns: 1fr; }
    .hero-side { padding-bottom: 0; }
    .mac { grid-template-columns: 1fr; }
    .rows li { grid-template-columns: auto minmax(0, 1fr); }
    .prow { grid-template-columns: 1fr; }
    .pmain { grid-template-columns: 76px minmax(0, 1fr); }
    .pname { padding-left: 90px; margin-top: 0; }
    .pport { font-size: 19px; }
    .card.was .pcmd { padding-left: 90px; }
    .pacts { justify-content: flex-end; }
    .pline, .pdetails, .ptunnel, .qrs { padding-left: 18px; }
    .qr { margin-left: 18px; }
    .qrc .qr { margin-left: 0; }
    .pdetails { grid-template-columns: 5.5em minmax(0, 1fr) auto; }
    .apps li { grid-template-columns: minmax(0, 1fr) auto 5em; grid-template-areas: "nm val slot" "bar bar bar"; row-gap: 6px; padding: 6px 0; }
    .apps .nm { grid-area: nm; } .apps .val { grid-area: val; } .apps .slot { grid-area: slot; } .apps .track { grid-area: bar; }
    .nav-meta { display: none; }
  }
  @media (prefers-reduced-motion: reduce) { * { transition: none !important; animation: none !important; } }
</style>
</head>
<body>
<header class="top">
  <div class="wrap">
    <nav class="nav">
      <span class="brand">
        <span class="logo">
          <svg viewBox="0 0 26 18" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M1 6c2.5-2.4 4.5-2.4 7 0s4.5 2.4 7 0 4.5-2.4 7 0"/><path d="M1 13c2.5-2.4 4.5-2.4 7 0s4.5 2.4 7 0 4.5-2.4 7 0"/></svg>
          __app__
        </span>
        <a class="gh" href="https://github.com/ips610/harbor" target="_blank" rel="noopener noreferrer" aria-label="__app__ on GitHub" title="__app__ on GitHub"><svg viewBox="0 0 16 16" aria-hidden="true" focusable="false"><path d="M8 0c4.42 0 8 3.58 8 8a8.013 8.013 0 0 1-5.45 7.59c-.4.08-.55-.17-.55-.38 0-.27.01-1.13.01-2.2 0-.75-.25-1.23-.54-1.48 1.78-.2 3.65-.88 3.65-3.95 0-.88-.31-1.59-.82-2.15.08-.2.36-1.02-.08-2.12 0 0-.67-.22-2.2.82-.64-.18-1.32-.27-2-.27-.68 0-1.36.09-2 .27-1.53-1.03-2.2-.82-2.2-.82-.44 1.1-.16 1.92-.08 2.12-.51.56-.82 1.28-.82 2.15 0 3.06 1.86 3.75 3.64 3.95-.23.2-.44.55-.51 1.07-.46.21-1.61.55-2.33-.66-.15-.24-.6-.83-1.23-.82-.67.01-.27.38.01.53.34.19.73.9.82 1.13.16.45.68 1.31 2.69.94 0 .67.01 1.3.01 1.49 0 .21-.15.45-.55.38A7.995 7.995 0 0 1 0 8c0-4.42 3.58-8 8-8Z"/></svg></a>
      </span>
      <span class="nav-end">
        <span class="nav-meta mono">Ports on this Mac</span>
        <span class="seg small" role="group" aria-label="Appearance">
          <button type="button" data-appearance="auto" aria-pressed="false">Auto</button>
          <button type="button" data-appearance="light" aria-pressed="false">Light</button>
          <button type="button" data-appearance="dark" aria-pressed="false">Dark</button>
        </span>
      </span>
    </nav>
    <div class="strip mono">
      <span><i class="dot" id="live-dot"></i><span id="st-live">Connecting</span></span>
      <span id="st-net"></span>
      <span id="st-scan">127.0.0.1 only</span>
      <span id="st-note" hidden></span>
    </div>
    <div class="hero">
      <h1 class="hero-num display" aria-live="polite"><span id="hero-num">–</span><small id="hero-unit">servers</small></h1>
      <div class="hero-side">
        <p class="hero-label mono" id="hero-label">Listening on this Mac</p>
        <p class="hero-lede" id="hero-lede">Reading the port table…</p>
      </div>
    </div>
    <div class="map" aria-hidden="true">
      <div class="ticks" id="ticks"></div>
      <div class="axis mono" id="axis"></div>
    </div>
    <ul class="legend mono" id="legend"></ul>
  </div>
</header>

<div class="alarm" id="alarm" hidden><div class="wrap"><p id="alarm-text"></p><span id="alarm-act"></span></div></div>
<div id="notices"></div>
<div class="notice update" id="update-notice" hidden><div class="wrap"><p id="update-text"></p><a class="btn" id="update-get" target="_blank" rel="noopener">Get it</a><button class="btn" id="update-now" type="button" hidden>Update now</button></div></div>
<div class="offline" id="offline" hidden><div class="wrap" id="offline-text">__APP__ isn't answering. Open it from the menu bar or Applications, then reload this page.</div></div>

<main class="wrap">
  <section id="s-ports" style="--sec: var(--c-ports)">
    <div class="sec-head">
      <div>
        <div class="sec-title"><span class="sec-num">01</span><h2 class="display">Ports</h2></div>
        <p class="sec-sub" id="ports-sub">Open, copy, share or kill each one. Click a row for details.</p>
      </div>
      <div class="controls">
        <div class="seg" role="group" aria-label="Group ports">
          <button type="button" data-group="project" aria-pressed="true">Project</button>
          <button type="button" data-group="category" aria-pressed="false">Category</button>
          <button type="button" data-group="flat" aria-pressed="false">Flat</button>
        </div>
        <span class="range" title="Ports outside this range are hidden, like Manfath's visible range.">Ports
          <input type="number" id="rmin" min="1" max="65535" aria-label="Lowest port shown"> –
          <input type="number" id="rmax" min="1" max="65535" aria-label="Highest port shown"></span>
        <label class="check"><input type="checkbox" id="only-servers"> Servers only</label>
        <label class="check"><input type="checkbox" id="show-system"> <span id="show-system-label">macOS services</span></label>
      </div>
    </div>
    <div class="cards" id="cards"></div>
    <div class="cards" id="stopped"></div>
    <p class="hidden-note" id="hidden-note"></p>
  </section>

  <section id="s-mac" style="--sec: var(--c-mac)">
    <div class="sec-head">
      <div>
        <div class="sec-title"><span class="sec-num">02</span><h2 class="display">This Mac</h2></div>
        <p class="sec-sub">Memory, and the apps holding most of it.</p>
      </div>
    </div>
    <div class="mac" id="mac"></div>
  </section>

  <section class="settings" aria-label="Settings">
    <b>Settings</b>
    <label class="check"><input type="checkbox" id="login-item"> Open __APP__ at login</label>
    <label class="check"><input type="checkbox" id="show-dock"> Show __APP__ in the Dock</label>
    <span class="check">Appearance
      <span class="seg small" role="group" aria-label="Appearance">
        <button type="button" data-appearance="auto" aria-pressed="false">Auto</button>
        <button type="button" data-appearance="light" aria-pressed="false">Light</button>
        <button type="button" data-appearance="dark" aria-pressed="false">Dark</button>
      </span>
    </span>
    <span class="check" id="update-row"></span>
    <span id="settings-note"></span>
  </section>
</main>

<div class="pill" role="search">
  <span class="status mono"><i class="dot" id="pill-dot"></i><span id="pill-status">Live</span></span>
  <input id="q" type="search" placeholder="Filter by port, project or PID" autocomplete="off" spellcheck="false" aria-label="Filter ports">
  <button type="button" class="pill-refresh" id="refresh" title="Scan again now">Refresh</button>
</div>
<div class="toast" id="toast" role="status" hidden></div>

<dialog id="dlg">
  <form method="dialog">
    <h3 id="dlg-title"></h3>
    <p id="dlg-body"></p>
    <input id="dlg-input" type="text" maxlength="50" autocomplete="off" autocapitalize="off" spellcheck="false" aria-labelledby="dlg-title" hidden>
    <div class="dlg-actions">
      <button class="btn" value="no" id="dlg-no">Cancel</button>
      <button class="btn danger" value="yes" id="dlg-yes"></button>
    </div>
  </form>
</dialog>

<script nonce="__NONCE__">
'use strict';
const $ = (id) => document.getElementById(id);
const PALETTE = ['#4f8cf7', '#19a77d', '#9a84f4', '#de5a88', '#cf9214', '#16a6c2', '#e8743f', '#6b8f2a'];
// The scan interval is a setting in the app (shared with the menu); 0 = manual.
function pollMs() { const s = state ? state.settings.interval : 15; return s > 0 ? s * 1000 : 0; }
function cadence() {
  const s = state ? state.settings.interval : 15;
  return s === 0 ? 'refreshes when you click Refresh or come back to the tab' : s === 60 ? 'refreshes every minute while open' : `refreshes every ${s} s while open`;
}
let state = null, timer = null, group = 'project', query = '';
const phase = new Map();   // row id -> { kind: confirm|working|force|admin|msg, text }
const opened = new Set();  // expanded row ids
const busy = new Set();
const sig = {};
const sharing = new Map();  // row id -> { kind: confirm|hint, text, command }
const qrShown = new Set();  // ports showing a QR code
const lanShown = new Set(); // rows showing "open on another device"
const lanAsk = new Map();   // row id -> the password suggested while "on network" is being turned on
const lanFor = new Map();   // row id -> how long it is to stay on the network: null while that is being chosen, then the seconds
const lanSeen = new Map();  // row id -> the network password, while "show" is on
const swapHist = [];        // swap in use, one sample per poll, only while the page is open
const qrCache = new Map();

function store(key, value) { try { localStorage.setItem(key, value); } catch (e) {} }
function load(key) { try { return localStorage.getItem(key); } catch (e) { return null; } }
// The grouping is a setting in the app, shared with the menu; see render().

// Build DOM without ever parsing strings as HTML.
function el(tag, props, ...kids) {
  const n = document.createElement(tag);
  for (const [k, v] of Object.entries(props || {})) {
    if (v == null || v === false) continue;
    if (k === 'text') n.textContent = v;
    else if (k === 'class') n.className = v;
    else if (k === 'style') for (const [sk, sv] of Object.entries(v)) n.style.setProperty(sk, sv);
    else if (k.startsWith('on')) n.addEventListener(k.slice(2), v);
    else n.setAttribute(k, v === true ? '' : String(v));
  }
  for (const kid of kids.flat()) if (kid != null && kid !== false) n.append(kid instanceof Node ? kid : String(kid));
  return n;
}
function swap(id, signature, build) {
  if (sig[id] === signature) return;
  sig[id] = signature;
  $(id).replaceChildren(...[].concat(build()));
}

function bytes(b) {
  if (b == null) return '–';
  const gb = b / 1073741824;
  if (gb >= 10) return gb.toFixed(0) + ' GB';
  if (gb >= 1) return gb.toFixed(1) + ' GB';
  return Math.max(1, Math.round(b / 1048576)) + ' MB';
}
function uptime(s) {
  if (s == null) return '';
  s = Math.floor(s);
  if (s < 60) return s + ' s';
  if (s < 3600) return Math.floor(s / 60) + ' min';
  if (s < 86400) { const h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60); return m ? `${h} h ${m} min` : `${h} h`; }
  const d = Math.floor(s / 86400); return d === 1 ? '1 day' : d + ' days';
}
function hash(text) { let h = 0; for (const c of text) h = (h * 31 + c.charCodeAt(0)) | 0; return Math.abs(h); }
function colour(key) { return PALETTE[hash(key) % PALETTE.length]; }
function plural(n, one, many) { return n === 1 ? `1 ${one}` : `${n} ${many}`; }

__SESSION__
__QR__
// The banner under the header: one line, or a few.
function banner(lines, status) {
  $('offline').hidden = false;
  $('offline-text').replaceChildren(...lines.map((text) => el('div', { text })));
  setLive(false, status);
}

// Signed out: say what's happening, unless another tab signed in meanwhile.
async function gate() {
  const lines = await signedOut();
  if (!key) banner(lines, lines[0] === QUIT_TEXT ? 'Quit' : 'Signed out');
}

// The rows on screen right now. Only those are asked what they serve, and harbor itself
// decides how many at a time and how often; a hidden tab doesn't poll at all.
function onScreen() {
  const ids = [];
  for (const li of document.querySelectorAll('li[data-id]')) {
    const r = li.getBoundingClientRect();
    if (r.height > 0 && r.bottom > 0 && r.top < innerHeight) ids.push(li.dataset.id);
  }
  return ids.slice(0, 40);
}
let seen = '';
async function poll() {
  clearTimeout(timer);
  timer = null;
  if (document.visibilityState !== 'visible') return;
  // No key yet: don't ask for data, ask harbor for a signed-in tab.
  if (!key) return gate();
  seen = onScreen().join(',');
  try {
    const next = await api('/api/state' + (seen ? '?see=' + seen : ''));
    if (next.quit) {
      // harbor was quit from its menu: stop asking, or launchd would start it again.
      banner([QUIT_TEXT], 'Quit');
      return;
    }
    state = next;
    swapHist.push(state.memory.swapUsed);
    if (swapHist.length > 40) swapHist.shift();
    $('offline').hidden = true;
    render();
  } catch (e) {
    // The cookie or the key no longer matches (a new one is made every 30 days).
    if (e.message === 'session') return gate();
    banner(["__APP__ isn't answering. Open it from the menu bar or Applications, then reload this page."], 'Not answering');
  }
  // Quicker while an update check runs, so its answer shows up straight away; and while a
  // row's answer is on its way, or rows have come on screen that harbor hasn't been told of.
  const soon = state && (state.asking || onScreen().join(',') !== seen);
  const wait = state && state.update && state.update.checking ? 1000 : soon ? 1200 : pollMs();
  if (document.visibilityState === 'visible' && wait > 0) timer = setTimeout(poll, wait);
}
// Scrolled to other rows: tell harbor once the scrolling has stopped.
let scrolled = null;
window.addEventListener('scroll', () => {
  clearTimeout(scrolled);
  scrolled = setTimeout(() => { if (state && onScreen().join(',') !== seen) poll(); }, 400);
}, { passive: true });
window.addEventListener('focus', () => poll());
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') poll();
  else { clearTimeout(timer); timer = null; setLive(false, 'Paused'); }
});

function setLive(on, text) {
  $('live-dot').className = on ? 'dot' : 'dot off';
  $('pill-dot').className = on ? 'dot' : 'dot off';
  $('st-live').textContent = text;
  $('pill-status').textContent = on ? 'Live' : text;
}

// ---------- rendering ----------
function visiblePorts() {
  const all = state.ports.filter((p) => !p.hidden);
  if (!query) return all;
  const q = query.toLowerCase();
  return all.filter((p) => String(p.port).startsWith(q) || String(p.pid) === q ||
    [p.name, p.display, p.title, p.framework, p.project, p.command, p.app, p.host].some((v) => v && v.toLowerCase().includes(q)));
}

function groupKey(p) { return p.group || (p.projectPath ? 'p:' + p.projectPath : 'a:' + (p.app || p.name)); }

function groups(ports) {
  const map = new Map();
  for (const p of ports) {
    const key = groupKey(p);
    if (!map.has(key)) map.set(key, {
      key, rows: [], rank: p.isProject ? 0 : p.projectPath || (p.container && p.container.project) ? 1 : 2,
      title: p.groupTitle || p.project || p.app || p.name, path: p.projectPath, folder: p.projectPath ? p.folder : null,
      // Docker's: a compose project, or the containers that belong to none.
      sub: p.container ? (p.container.project ? 'Docker Compose project' : 'Docker containers') : null,
    });
    map.get(key).rows.push(p);
  }
  return [...map.values()]
    .map((g) => ({ ...g, rows: g.rows.sort((a, b) => a.port - b.port) }))
    .sort((a, b) => a.rank - b.rank || a.title.localeCompare(b.title, undefined, { sensitivity: 'base' }) || a.rows[0].port - b.rows[0].port);
}

function render() {
  if (state.settings.grouping) group = state.settings.grouping;
  const all = state.ports.filter((p) => !p.hidden);
  const ports = visiblePorts();
  setLive(true, `Updated ${Math.round(state.scannedAgo)}s ago`);
  const net = state.network || {};
  $('st-net').textContent = net.ip ? 'On your network: ' + [net.ip, net.name].filter(Boolean).join(' · ') : 'Not on a network';
  $('st-scan').textContent = `${location.host} · this Mac only · scanned in ${state.scanMs.toFixed(0)} ms · ${cadence()}`;
  // Only when the app had to move off its usual port, or port 80 isn't its door's.
  $('st-note').textContent = (state.portNotes || []).join(' · ');
  $('st-note').hidden = !(state.portNotes || []).length;
  renderHero(all);
  renderAlarm();
  renderNotices();
  renderUpdate();
  renderPorts(ports, all);
  renderMac();
  $('login-item').checked = !!state.loginItem;
  $('show-dock').checked = !!state.settings.showInDock;
  applyTheme(state.settings.appearance);
  $('settings-note').textContent = state.settings.interval > 0
    ? `Scans every ${state.settings.interval} s while the menu or this page is open; change it in the menu bar.`
    : 'Scans only when you open the menu or this page; change it in the menu bar.';
}

function renderHero(all) {
  const title = all.length ? `__app__ • ${plural(all.length, 'port', 'ports')}` : '__app__';
  if (document.title !== title) document.title = title;
  const gs = groups(all);
  const projects = gs.filter((g) => g.rank === 0).length;
  const apps = gs.length - projects;
  const exposed = all.filter((p) => p.exposed).length;
  $('hero-num').textContent = String(all.length);
  $('hero-unit').textContent = all.length === 1 ? 'server' : 'servers';
  const lede = $('hero-lede');
  let who;
  if (projects && apps) who = `${plural(projects, 'project', 'projects')} and ${plural(apps, 'other app', 'other apps')} are`;
  else if (projects) who = projects === 1 ? '1 project is' : `${projects} projects are`;
  else who = apps === 1 ? '1 app is' : `${apps} apps are`;
  const first = all.length === 0 ? 'Nothing is listening right now.' : `${who} serving on this Mac.`;
  const shared = all.filter((p) => p.tunnel && p.tunnel.state === 'ready').length;
  const sigText = first + '|' + exposed + '|' + shared;
  if (sig.lede !== sigText) {
    sig.lede = sigText;
    lede.replaceChildren(first);
    if (exposed) lede.append(' ', el('span', { class: 'warn', text: `${plural(exposed, 'port is', 'ports are')} reachable from your network.` }));
    if (shared) lede.append(' ', el('span', { class: 'warn', text: `${plural(shared, 'port is', 'ports are')} shared to the internet.` }));
  }

  // Port map: log scale from 1,000 to 65,535; lit ticks are listening ports.
  const n = window.innerWidth < 640 ? 44 : 88;
  const lo = Math.log(1000), hi = Math.log(65536);
  const pos = (port) => Math.min(n - 1, Math.max(0, Math.floor((Math.log(Math.max(port, 1000)) - lo) / (hi - lo) * n)));
  const lit = new Map();
  for (const p of all) { const i = pos(p.port); if (!lit.has(i)) lit.set(i, []); lit.get(i).push(p); }
  swap('ticks', n + JSON.stringify([...lit].map(([i, ps]) => [i, ps.map((p) => p.port + groupKey(p))])), () => {
    const out = [];
    for (let i = 0; i < n; i++) {
      const ps = lit.get(i);
      out.push(ps ? el('i', { class: 'on', title: ps.map((p) => `:${p.port} ${p.title}`).join('\n'), style: { 'background-color': ps[0].color } }) : el('i'));
    }
    return out;
  });
  const marks = n < 60 ? [1000, 3000, 5000, 10000, 20000, 40000] : [1000, 2000, 3000, 5000, 8000, 10000, 20000, 40000];
  swap('axis', String(n), () => marks.map((v) =>
    el('span', { text: v >= 1000 ? (v / 1000) + 'k' : String(v), style: { left: ((Math.log(v) - lo) / (hi - lo) * 100).toFixed(2) + '%' } })));
  const gs2 = groups(all).slice(0, window.innerWidth < 640 ? 4 : 6);
  swap('legend', JSON.stringify(gs2.map((g) => [g.key, g.rows.length])), () => gs2.map((g) =>
    el('li', {}, el('i', { class: 'sw', style: { background: g.rows[0].color } }), el('b', { text: g.title }), ' ' + g.rows.map((p) => ':' + p.port).join(' '))));
}

function renderAlarm() {
  const z = state.zombies;
  const p = z.alarm && z.parents[0];
  $('alarm').hidden = !p;
  if (!p) return;
  swap('alarm-text', JSON.stringify([p.pid, p.count, z.count]), () => [
    el('b', { text: p.name }), ` is holding ${p.count.toLocaleString()} stuck processes. Past about ${z.perUser.toLocaleString()}, this Mac can't open anything new.`,
  ]);
  swap('alarm-act', JSON.stringify([p.pid, p.canQuit, busy.has(p.pid)]), () => p.canQuit
    ? (busy.has(p.pid) ? el('span', { class: 'busy' }, el('i', { class: 'spinner' }), 'Quitting')
      : el('button', { class: 'btn', text: `Quit ${p.name}`, onclick: () => quitProcess(p.pid, p.name, `It has ${p.count} stuck child processes. Quitting it lets macOS clear them.`) }))
    : []);
}

// The app asks GitHub at most once a day; the button asks now.
function renderUpdate() {
  const u = state.update;
  $('update-notice').hidden = !u.newer;
  // With "Update now" there, the link beside it is the release's page; without it, the link is how to get it.
  $('update-text').textContent = !u.newer ? '' : u.problem ? `__app__ ${u.latest} is out. ${u.problem}`
    : u.canUpdate ? `__app__ ${u.latest} is out.` : `__app__ ${u.latest} is out. Download it, unzip it and drag it into Applications over this one.`;
  $('update-get').href = u.url;
  $('update-now').hidden = !u.canUpdate;
  $('update-now').disabled = !!u.updating;
  $('update-now').textContent = u.updating ? 'Updating…' : 'Update now';
  const note = u.checking ? 'Checking GitHub…' : u.failed ? "GitHub didn't answer. Try again later."
    : u.newer ? `${u.latest} is out` : u.latest ? 'up to date' : '';
  swap('update-row', JSON.stringify([u.current, note, u.checking]), () => [
    `__app__ ${u.current}` + (note ? ` · ${note}` : ''),
    el('button', { class: 'btn quiet', type: 'button', text: u.checking ? 'Checking…' : 'Check for updates', disabled: u.checking,
      onclick: async () => { await act('check-update', 0); poll(); } }),
  ]);
}

function renderNotices() {
  swap('notices', JSON.stringify(state.notices.map((n) => n.id)), () => state.notices.slice(-2).map((n) =>
    el('div', { class: 'notice' }, el('div', { class: 'wrap' }, el('p', { text: n.text }),
      el('button', { class: 'btn quiet', text: 'Dismiss', onclick: async () => { await api('/api/action', { op: 'dismiss-notice', id: n.id }).catch(() => {}); poll(); } })))));
}

const CATEGORY_ORDER = ['dev', 'database', 'runtime', 'appHelper', 'other', 'system'];

function renderPorts(ports, all) {
  const st = state.settings;
  const hidden = state.ports.filter((p) => p.hidden).length;
  const systemCount = state.ports.filter((p) => p.system).length;
  $('show-system').checked = st.showSystem;
  $('only-servers').checked = st.onlyServers;
  $('show-system-label').textContent = systemCount ? `macOS services (${systemCount})` : 'macOS services';
  for (const [id, v] of [['rmin', st.minPort], ['rmax', st.maxPort]]) if (document.activeElement !== $(id)) $(id).value = v;
  $('hidden-note').textContent = hidden
    ? `${plural(hidden, 'port is', 'ports are')} hidden by the range ${st.minPort}–${st.maxPort}${st.showSystem ? '' : ', macOS services'}${st.onlyServers ? ', the servers-only filter' : ''}.` : '';
  for (const b of document.querySelectorAll('[data-group]')) b.setAttribute('aria-pressed', String(b.dataset.group === group));

  let model;
  if (group === 'project') model = groups(ports).map((g) => ({ ...g, kind: 'card' }));
  else if (group === 'category') model = CATEGORY_ORDER.map((c) => {
    const rows = ports.filter((p) => p.category === c).sort((a, b) => a.port - b.port);
    return rows.length ? { key: 'c:' + c, kind: 'section', title: rows[0].categoryTitle, rows } : null;
  }).filter(Boolean);
  else model = [{ key: 'flat', kind: 'section', title: 'All ports', rows: [...ports].sort((a, b) => a.port - b.port) }];

  const shape = model.map((g) => [g.key, g.rows.map((p) => [p.id, p.title, p.name, p.framework, p.command, p.address,
    uptime(p.uptime), bytes(p.memory), p.workers, p.busy, p.system, p.hint, phase.get(p.id), opened.has(p.id),
    p.tunnel, sharing.get(p.id), qrShown.has(p.port), state.share.available, lanShown.has(p.id), p.lan, p.lanBonjour, p.net,
    p.lanReachable, p.loopbackOnly, p.macos, state.network, p.host, p.local, lanAsk.get(p.id), lanSeen.get(p.id),
    // What a container is, what the row last answered, and how long a share is being asked to last or has left.
    p.container, p.nokill, p.served, lanFor.has(p.id) ? String(lanFor.get(p.id)) : '', state.lasts, p.watched, p.log])]);
  swap('cards', group + query + JSON.stringify(shape), () => {
    $('cards').className = group === 'project' ? 'cards' : 'stack-list';
    if (!ports.length) {
      return el('div', { class: 'empty' }, el('b', { text: query ? 'No matches' : 'No services listening' }),
        query ? 'Try a port number, a project name or a PID.' : "Start a dev server and it'll show up here within a few seconds.");
    }
    return model.map((g) => g.kind === 'card' ? card(g) : section(g));
  });
  swap('stopped', JSON.stringify([state.stopped.map((s) => [s.id, s.name, s.port, s.folder, s.command, uptime(s.ago), s.note, s.log]), [...busyStart]]),
    () => state.stopped.length ? stoppedCard(state.stopped) : []);
}

// Servers harbor saw stop. Each can be started again: the request names the entry and nothing else.
const busyStart = new Set();
function stoppedCard(list) {
  const pill = (text, cls, onclick, extra) => el('button', { class: 'pl ' + (cls || ''), text, onclick, ...(extra || {}) });
  return el('article', { class: 'card was' },
    el('div', { class: 'card-head' }, el('div', { class: 'card-title' }, el('h3', { text: 'Stopped' }),
      el('p', { class: 'card-path mono', text: 'Servers that were running here. Started again, a server has no Terminal: its output goes to a log.' }))),
    el('ul', { class: 'rows' }, list.map((s) => el('li', {},
      el('div', { class: 'prow' },
        el('div', { class: 'pmain' }, el('span', { class: 'pport', text: ':' + s.port }),
          el('div', { class: 'ptext' }, el('div', { class: 'ptitle' }, el('span', { class: 't', text: s.name })),
            el('div', { class: 'psub', text: s.folder + ' · stopped ' + uptime(s.ago) + ' ago' }))),
        el('div', { class: 'pacts' },
          busyStart.has(s.id) ? el('span', { class: 'busy' }, el('i', { class: 'spinner' }), 'starting')
            : pill('start again', 'open', () => startAgain(s), { title: 'Run it again, as it was started' }),
          s.log ? pill('show log', '', async () => { const r = await api('/api/action', { op: 'show-log', id: s.id }).catch((e) => toast(e.message)); if (r) toast(r.message); }) : null),
        el('div', { class: 'pcmd', text: s.command })),
      s.note ? el('p', { class: 'pline', text: s.note }) : null))));
}
async function startAgain(s) {
  if (!await ask(`Start ${s.name} again?`, s.question, 'Start', false)) return;
  busyStart.add(s.id); render();
  try { const r = await api('/api/action', { op: 'start-again', id: s.id }); toast(r.message); }
  catch (e) { toast(e.message); }
  busyStart.delete(s.id);
  poll();
}
// A small bell: tell me when this one server stops.
function bell(on) {
  const NS = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(NS, 'svg');
  svg.setAttribute('viewBox', '0 0 16 16'); svg.setAttribute('aria-hidden', 'true');
  const path = document.createElementNS(NS, 'path');
  path.setAttribute('d', 'M8 1.5a4.5 4.5 0 0 0-4.5 4.5c0 3-1.5 4-1.5 5.5h12c0-1.5-1.5-2.5-1.5-5.5A4.5 4.5 0 0 0 8 1.5zM6.5 13a1.5 1.5 0 0 0 3 0');
  path.setAttribute('fill', on ? 'currentColor' : 'none'); path.setAttribute('stroke', 'currentColor'); path.setAttribute('stroke-width', '1.3'); path.setAttribute('stroke-linejoin', 'round');
  svg.append(path);
  return svg;
}

function card(g) {
  const mac = g.rows.every((p) => p.macos);
  const frameworks = [...new Set(g.rows.map((p) => p.framework).filter(Boolean))];
  const onNetwork = g.rows.find((p) => p.local && p.local.on);
  const head = el('div', { class: 'card-head' },
    el('div', { class: 'card-title' },
      el('h3', { text: g.title }),
      mac ? el('p', { class: 'card-badge' }, macGlyph(), 'macOS service')
        : el('p', { class: 'card-path mono', text: g.path || g.sub || 'App or service' }),
      frameworks.length || onNetwork ? el('div', { class: 'chips' }, frameworks.map((f) => el('span', { class: 'chip', text: f })),
        onNetwork ? el('span', { class: 'chip warn', text: 'on network', title: onNetwork.local.link }) : null) : null),
    el('span', { class: 'card-acts' },
      g.folder ? el('button', { class: 'btn quiet', text: 'Reveal', title: 'Show this folder in Finder', onclick: () => act('reveal', g.rows[0].pid) }) : null));
  return el('article', { class: 'card' + (mac ? ' mac-svc' : ''), style: { '--pc': g.rows[0].color } },
    head, el('ul', { class: 'rows' }, g.rows.map((p) => row(p, false))));
}

function section(g) {
  return el('article', { class: 'group' },
    el('div', { class: 'group-title mono' }, el('b', { text: g.title }), String(g.rows.length)),
    el('ul', { class: 'rows' }, g.rows.map((p) => row(p, true))));
}

// One Manfath-style row: ":3000  name [tags]  …  open copy kill", click for details.
function row(p, showProject) {
  const ph = phase.get(p.id);
  const sh = sharing.get(p.id);
  const live = p.tunnel && p.tunnel.state === 'ready' ? p.tunnel : null;
  const title = showProject ? p.title : p.display;
  const facts = [title !== p.name ? p.name : null,
    'pid ' + p.pid + (p.workers ? ` +${p.workers}` : ''),
    p.uptime != null ? 'up ' + uptime(p.uptime) : null, p.memory != null ? bytes(p.memory) : null].filter(Boolean).join(' · ');
  const stop = (e) => e.stopPropagation();
  const pill = (text, cls, onclick, extra) => el('button', { class: 'pl ' + (cls || ''), text, onclick: (e) => { stop(e); onclick(); }, ...(extra || {}) });

  let acts;
  if (ph && ph.kind === 'working' || p.busy) acts = el('span', { class: 'busy' }, el('i', { class: 'spinner' }), 'stopping');
  else if (ph && ph.kind === 'confirm') acts = [pill('confirm?', 'confirm', () => runStop(p, 'stop')), pill('cancel', '', () => setPhase(p.id, null))];
  else if (ph && ph.kind === 'force') acts = [pill('force kill', 'force', () => runStop(p, 'force')), pill('cancel', '', () => setPhase(p.id, null))];
  else if (ph && ph.kind === 'admin') acts = [pill('admin password…', 'admin', () => runStop(p, 'admin')), pill('cancel', '', () => setPhase(p.id, null))];
  else if (sh && sh.kind === 'confirm') acts = [...lasting('public', pill, (seconds) => startShare(p, seconds)), pill('cancel', '', () => setShare(p.id, null))];
  else acts = [
    el('a', { class: 'pl open', href: safeUrl(address(p)), target: '_blank', rel: 'noopener noreferrer', text: 'open', title: 'Open ' + address(p), onclick: stop }),
    pill('copy', '', () => copy(p), { title: 'Copy ' + address(p) }),
    p.system ? null : qrButton(p),
    p.system ? null : shareAction(p, pill),
    p.system || p.nokill ? null : pill('kill', 'kill', () => armKill(p), { title: `Kill PID ${p.pid}` }),
  ];

  const isOpen = opened.has(p.id);
  const area = !p.system && (lanShown.has(p.id) || isOpen);
  const li = el('li', { class: isOpen ? 'open' : '', 'data-id': p.id },
    el('div', { class: 'prow', role: 'button', tabindex: '0', 'aria-expanded': String(isOpen),
      onclick: () => toggle(p.id), onkeydown: (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggle(p.id); } } },
      el('div', { class: 'pmain' },
        el('span', { class: 'pport', text: ':' + p.port }),
        el('div', { class: 'ptext' },
          el('div', { class: 'ptitle' }, el('span', { class: 't', text: title }),
            p.framework && p.framework !== title ? el('span', { class: 'tag', text: p.framework }) : null,
            p.macos ? el('span', { class: 'tag macos', title: 'A macOS service' }, macGlyph(), 'macOS') : null,
            p.exposed ? el('span', { class: 'tag warn', text: p.address, title: 'Other devices on your network can reach this port.' }) : null,
            p.local && p.local.on ? el('span', { class: 'tag warn', text: 'on network', title: 'Other devices on this network open it at ' + p.local.link }) : null,
            live ? el('span', { class: 'tag shared', text: 'shared', title: 'Public link: ' + live.url }) : null),
          el('div', { class: 'psub' }, netAddress(p), ' · ' + facts))),
      el('div', { class: 'pacts' }, acts),
      // Its name, with the plain address beside it.
      p.host ? el('div', { class: 'pname' }, el('a', { href: safeUrl(p.hostUrl), target: '_blank', rel: 'noopener noreferrer', text: p.host, title: 'Open ' + p.hostUrl, onclick: stop }),
        ' · ' + p.url.replace('http://', '')) : null,
      p.host && p.served ? el('div', { class: 'pname pserved', text: p.served, title: 'What it answered when __app__ last asked' }) : null),
    ph && ph.text ? el('p', { class: 'pline' + (ph.kind === 'msg' ? ' info' : '') , text: ph.text }) : null,
    sh && sh.kind === 'confirm' ? el('p', { class: 'pline share', text: sh.text }) : null,
    sh && sh.kind === 'hint' ? el('p', { class: 'pline info' }, sh.text + ' ', el('code', { text: sh.command }), ' ',
      pill('copy command', '', () => copyText(sh.command))) : null,
    tunnelLine(p, pill, area),
    live && qrShown.has(p.port) && !area ? qrBox(p.port) : null,
    // The QR area: open from the QR pill, and always part of the details. It holds every
    // code the row has (two when it is on the network and has a public link as well).
    // On the network as <name>.local: that link, its password and its QR. Otherwise the
    // plain address (or why a phone can't reach it), with the switch under it. Its name on
    // this Mac sits right above its name on the network: a pair, each with its own rename.
    area ? (p.local && p.local.on ? [thisMac(p, pill), networkBox(p, pill)]
      : [p.lanReachable ? lanBox(p, pill) : loopBox(p, pill, live), thisMac(p, pill), p.local ? networkOffer(p, pill) : null]) : null,
    isOpen ? details(p) : null);
  return li;
}

function details(p) {
  const items = [];
  const add = (label, value, action) => items.push(el('dt', { text: label }), el('dd', { text: value }), action || el('span'));
  if (p.container) {
    add('Container', p.container.name);
    if (p.container.image) add('Image', p.container.image);
    if (p.container.project) add('Compose', p.container.project + (p.container.service ? ' / ' + p.container.service : ''));
  }
  if (p.nokill) add('Kill', p.nokill);
  if (p.folder) add('Folder', p.folder, el('button', { class: 'pl', text: 'reveal', onclick: () => act('reveal', p.pid) }));
  if (p.command) add('Command', p.command);
  add('Address', p.address);
  add('URL', p.url, el('button', { class: 'pl', text: 'copy', onclick: () => copyText(p.url) }));
  if (p.memory != null) add('Memory', bytes(p.memory));
  if (!p.system) add('When it stops', p.watched ? 'you get a notification' : 'nothing is said',
    el('button', { class: 'pl bell' + (p.watched ? ' open' : ''), 'aria-pressed': String(!!p.watched), title: p.watched ? 'Stop watching this server' : 'Tell me when this server stops',
      onclick: async () => { const r = await act('watch', p.pid, { port: p.port, on: !p.watched }); if (r) toast(r.message); poll(); } }, bell(p.watched), p.watched ? 'watching' : 'tell me'));
  if (p.log) add('Output', 'in a log file: __app__ started it, so it has no Terminal',
    el('button', { class: 'pl', text: 'show log', onclick: async () => { const r = await act('show-log', p.pid); if (r) toast(r.message); } }));
  if (p.hint) add('Note', p.hint);
  return el('dl', { class: 'pdetails' }, items);
}

function toggle(id) { if (opened.has(id)) opened.delete(id); else opened.add(id); render(); }

function setPhase(id, value) { if (value) phase.set(id, value); else phase.delete(id); render(); }

// Like Manfath: "kill" becomes "confirm?", and an unanswered confirm goes back after 6 s.
function armKill(p) {
  const workers = p.workers ? ` and its ${plural(p.workers, 'worker', 'workers')}` : '';
  const where = p.folder ? `in ${p.folder}` : 'with no project folder';
  const entry = { kind: 'confirm', text: `Stop ${p.name} (pid ${p.pid})${workers} on :${p.port}, ${where}? Anything unsaved in it may be lost.` };
  setPhase(p.id, entry);
  setTimeout(() => { if (phase.get(p.id) === entry) setPhase(p.id, null); }, 6000);
}

async function runStop(p, op) {
  setPhase(p.id, { kind: 'working' });
  const r = await act(op, p.pid);
  if (!r) { setPhase(p.id, null); return; }
  if (r.result === 'still_running') setPhase(p.id, { kind: 'force', text: r.message });
  else if (r.result === 'not_permitted') setPhase(p.id, { kind: 'admin', text: r.message + ' macOS asks for the password in its own window; __APP__ never sees it.' });
  else if (r.result === 'system' || r.result === 'failed') setPhase(p.id, { kind: 'msg', text: r.message });
  else { setPhase(p.id, null); if (r.result !== 'cancelled') toast(r.message); }
  poll();
}

// A row's own address: its name (storefront.localhost) when it has one, else localhost:<port>.
function address(p) { return p.hostUrl || p.url; }
function safeUrl(url) {
  return /^http:\/\/(localhost|127\.0\.0\.1|\[[0-9a-f:]+\]|[0-9.]+):\d+$/i.test(url) || /^http:\/\/[a-z0-9-]+\.localhost(:\d+)?\/$/.test(url) ? url : '#';
}
function safePublic(url) { return /^https:\/\/[a-z0-9-]+\.(trycloudflare\.com|ngrok(-free)?\.(app|dev|io))\/?$/i.test(url) ? url : '#'; }

// ---------- share: Manfath's tunnel, always confirmed first ----------
function shareAction(p, pill) {
  if (p.tunnel && p.tunnel.state === 'starting') return el('span', { class: 'busy' }, el('i', { class: 'spinner' }), 'sharing');
  if (p.tunnel) return pill('unshare', 'kill', () => stopShare(p), { title: 'Stop sharing :' + p.port });
  return pill('share', 'share', () => askShare(p), { title: 'Get a public link for :' + p.port });
}
// How long a share lasts: a pill for each choice, the one made last time marked.
function lasting(kind, pill, go) {
  return state.lasts.choices.map((c) => pill(c.title, c.seconds === state.lasts[kind] ? 'go' : '', () => go(c.seconds)));
}
// The time a share has left, with half an hour more for the asking.
function timeLeft(p, pill, left, kind) {
  return left ? [el('span', { class: 'left', text: left }), pill('+30 min', '', async () => { const r = await act('more', p.pid, { port: p.port, kind }); if (r) toast(r.message); poll(); },
    { title: 'Half an hour more' })] : null;
}
function tunnelLine(p, pill, area) {
  if (!p.tunnel) return null;
  if (p.tunnel.state === 'starting') return el('p', { class: 'ptunnel', text: `Opening a public link with ${p.tunnel.provider}…` });
  if (p.tunnel.state !== 'ready') return el('p', { class: 'pline', text: p.tunnel.message || 'Sharing failed.' });
  const url = p.tunnel.url;
  return el('div', { class: 'ptunnel' }, 'Public link',
    el('a', { href: safePublic(url), target: '_blank', rel: 'noopener noreferrer', text: url, onclick: (e) => e.stopPropagation() }),
    pill('copy', '', () => copyText(url)),
    timeLeft(p, pill, p.tunnel.left, 'public'),
    // With the row's panel open its code is there already, beside the others.
    area ? null : pill(qrShown.has(p.port) ? 'hide qr' : 'qr', '', () => { if (qrShown.has(p.port)) qrShown.delete(p.port); else qrShown.add(p.port); render(); }));
}
// Its name on this Mac, shaped like the network line under it.
function thisMac(p, pill) {
  if (!p.host) return null;
  return el('div', { class: 'ptunnel' }, 'On this Mac',
    el('a', { href: safeUrl(p.hostUrl), target: '_blank', rel: 'noopener noreferrer', text: p.hostUrl, onclick: (e) => e.stopPropagation() }),
    pill('copy', '', () => copyText(p.hostUrl)), pill('rename', '', () => rename(p), { title: 'Change its .localhost name' }),
    // Another of the project's servers can be made the one its plain name opens.
    p.local && p.local.several && !p.local.main
      ? pill('make main', '', () => makeMain(p), { title: 'The project\'s plain name would open this server. What it has on the network comes off it.' }) : null);
}
async function makeMain(p) {
  const r = await act('main', p.pid, { port: p.port });
  if (r) toast(r.message);
  qrCache.clear();
  poll();
}
// The codes a row has (the server says which): one, as ever; or two side by side, each
// saying what it is, with its link and its own copy.
function codes(p, pill) {
  const box = (q) => qrBox(p.port, q.kind === 'share' ? undefined : q.kind);
  if (p.qrs.length < 2) return p.qrs.length ? box(p.qrs[0]) : null;
  const safe = (q) => q.kind === 'share' ? safePublic(q.link) : q.kind === 'name' ? safeLocal(q.link) : safeLan(q.link);
  return el('div', { class: 'qrs' }, p.qrs.map((q) => el('figure', { class: 'qrc' },
    el('figcaption', {}, q.label + ' ·',
      el('a', { href: safe(q), target: '_blank', rel: 'noopener noreferrer', text: q.link, onclick: (e) => e.stopPropagation() }),
      pill('copy', '', () => copyText(q.link))),
    box(q))));
}
// A compact QR glyph: "open it on another device on this network".
function qrButton(p) {
  const NS = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(NS, 'svg');
  svg.setAttribute('viewBox', '0 0 16 16'); svg.setAttribute('width', '14'); svg.setAttribute('height', '14'); svg.setAttribute('aria-hidden', 'true');
  for (const [x, y] of [[1, 1], [10, 1], [1, 10]]) {
    const r = document.createElementNS(NS, 'rect');
    r.setAttribute('x', x); r.setAttribute('y', y); r.setAttribute('width', 5); r.setAttribute('height', 5); r.setAttribute('rx', 1);
    r.setAttribute('fill', 'none'); r.setAttribute('stroke', 'currentColor'); r.setAttribute('stroke-width', '1.6');
    svg.append(r);
  }
  for (const [x, y] of [[10, 10], [13, 13], [13, 10], [10, 13]]) {
    const r = document.createElementNS(NS, 'rect');
    r.setAttribute('x', x); r.setAttribute('y', y); r.setAttribute('width', 2.2); r.setAttribute('height', 2.2); r.setAttribute('fill', 'currentColor');
    svg.append(r);
  }
  const on = lanShown.has(p.id) || opened.has(p.id);
  return el('button', { class: 'pl icon' + (on ? ' on' : ''), title: on ? 'Hide the QR code' : p.lanReachable ? 'Open it on another device on this network' : 'Open it on your phone',
    'aria-label': 'QR code for another device', 'aria-pressed': String(on),
    onclick: (e) => { e.stopPropagation(); if (on) { lanShown.delete(p.id); opened.delete(p.id); } else lanShown.add(p.id); render(); } }, svg);
}
// Where other devices reach a row (click copies the URL), or why they can't.
function netAddress(p) {
  if (p.net) return el('button', { class: 'netaddr', text: p.net, title: 'Copy http://' + p.net, onclick: (e) => { e.stopPropagation(); copyText('http://' + p.net); } });
  // Its own port is closed to them, but harbor answers for it under its name: say the name.
  if (p.local && p.local.on) return el('button', { class: 'netaddr', text: p.local.link.replace(/^http:\/\/|\/$/g, ''), title: 'Copy ' + p.local.link, onclick: (e) => { e.stopPropagation(); copyText(p.local.link); } });
  return el('span', { class: 'netaddr local', text: p.loopbackOnly ? 'this Mac only' : 'not on a network' });
}
// Loopback-only: phones can't reach it, so offer share; once shared, the public link's QR.
function loopBox(p, pill, live) {
  if (live) return el('div', {}, el('p', { class: 'pline info', text: "Phones can't reach 127.0.0.1, so this QR opens the public link." }), qrBox(p.port));
  if (p.tunnel && p.tunnel.state === 'starting') return el('p', { class: 'pline info', text: 'Opening a public link…' });
  const sh = sharing.get(p.id);
  return el('div', { class: 'ptunnel' }, "Phones can't reach 127.0.0.1. Share it to get a link and QR that work anywhere.",
    sh && sh.kind === 'confirm' ? null : pill('share', 'share', () => askShare(p)));
}
// A small computer glyph for macOS services (plain shapes, not Apple's logo).
function macGlyph() {
  const NS = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(NS, 'svg');
  svg.setAttribute('viewBox', '0 0 16 16'); svg.setAttribute('aria-hidden', 'true');
  const r = document.createElementNS(NS, 'rect');
  for (const [k, v] of Object.entries({ x: 1.5, y: 2, width: 13, height: 9, rx: 1.8, fill: 'none', stroke: 'currentColor', 'stroke-width': 1.7 })) r.setAttribute(k, v);
  const stand = document.createElementNS(NS, 'path');
  for (const [k, v] of Object.entries({ d: 'M5.5 14h5M8 11v3', stroke: 'currentColor', 'stroke-width': 1.7, 'stroke-linecap': 'round' })) stand.setAttribute(k, v);
  svg.append(r, stand);
  return svg;
}

function lanBox(p, pill) {
  if (!p.lan) return el('p', { class: 'pline info', text: "This Mac isn't on a network right now, so other devices can't reach it." });
  return el('div', {},
    el('div', { class: 'ptunnel' }, 'On your network',
      el('a', { href: safeLan(p.lan), target: '_blank', rel: 'noopener noreferrer', text: p.lan, onclick: (e) => e.stopPropagation() }),
      pill('copy', '', () => copyText(p.lan))),
    p.lanBonjour ? el('p', { class: 'pline info', text: 'Or ' + p.lanBonjour }) : null,
    codes(p, pill),
    state.network.firewall ? el('p', { class: 'pline info', text: 'The macOS firewall is on, so macOS may ask to allow incoming connections for this server.' }) : null);
}
function safeLan(u) { return /^http:\/\/[a-z0-9.\-]+:\d+\/?$/i.test(u) ? u : '#'; }

// ---------- on network: <name>.local for other devices on this Wi-Fi ----------
function safeLocal(u) { return /^http:\/\/[a-z0-9-]+\.local(:\d+)?\/$/.test(u) ? u : '#'; }
function setLanAsk(id, v) { if (v) lanAsk.set(id, v); else lanAsk.delete(id); render(); }
// Not on the network yet: the switch, and the name it would have there.
function networkOffer(p, pill) {
  // First how long, then (when the project has none yet) the password.
  if (lanFor.get(p.id) === null) return el('div', { class: 'ptunnel' }, 'On network for',
    lasting('network', pill, (seconds) => { lanFor.set(p.id, seconds); lanStart(p); }),
    pill('cancel', '', () => { lanFor.delete(p.id); render(); }));
  const suggested = lanAsk.get(p.id);
  if (suggested) return el('div', { class: 'ptunnel' }, 'Password', el('code', { text: suggested }),
    pill('use it', 'go', () => lanTurnOn(p, { password: suggested })),
    pill('type my own', '', async () => {
      const typed = await askText(`Password for ${p.local.name}.local`, 'At least 8 characters.', '', 'Turn on');
      if (typed != null) lanTurnOn(p, { password: typed });
    }),
    pill('no password', '', async () => {
      if (await ask('Share without a password?', p.local.anyone, 'Share')) lanTurnOn(p, { open: true });
    }),
    pill('cancel', '', () => { lanFor.delete(p.id); setLanAsk(p.id, null); }));
  return el('div', { class: 'ptunnel' }, 'On network as', el('code', { text: p.local.name + '.local' }),
    pill('turn on', 'open', () => { lanFor.set(p.id, null); render(); }, { title: 'Other devices on this Wi-Fi open it at http://' + p.local.name + '.local/' }),
    pill('rename', '', () => renameOnNetwork(p), { title: 'Change its name on the network' }));
}
// On the network: its link, its password, a QR for a phone, and what a password does and doesn't do.
function networkBox(p, pill) {
  const shown = lanSeen.get(p.id);
  return el('div', {},
    el('div', { class: 'ptunnel' }, 'On network',
      el('a', { href: safeLocal(p.local.link), target: '_blank', rel: 'noopener noreferrer', text: p.local.link, onclick: (e) => e.stopPropagation() }),
      pill('copy', '', () => copyText(p.local.link)), pill('rename', '', () => renameOnNetwork(p)),
      timeLeft(p, pill, p.local.left, 'network'),
      pill('turn off', 'kill', async () => { const r = await act('lan-off', p.pid, { port: p.port }); if (r) toast(r.message); lanSeen.delete(p.id); qrCache.delete('name' + p.port); poll(); })),
    el('div', { class: 'ptunnel' }, 'Password', p.local.password
      ? [el('code', { text: shown || '••••••••' }),
        pill(shown ? 'hide' : 'show', '', async () => {
          if (shown) lanSeen.delete(p.id); else { const r = await act('lan-show', p.pid, { port: p.port }); if (r && r.password) lanSeen.set(p.id, r.password); }
          render();
        }),
        pill('change', '', () => lanChange(p)),
        pill('new random one', '', () => lanPassword(p, { random: true })),
        pill('remove', '', async () => {
          if (await ask('Remove the password?', p.local.anyone, 'Remove')) lanPassword(p, { off: true });
        })]
      : ['none: anyone on this Wi-Fi can open it', pill('set one', '', () => lanPassword(p, { random: true }))]),
    p.local.note ? el('p', { class: 'pline info', text: p.local.note }) : null,
    p.local.help ? el('p', { class: 'pline info', text: p.local.help }) : null,
    p.local.trouble ? el('p', { class: 'pline share', text: p.local.trouble }) : null,
    codes(p, pill),
    el('p', { class: 'pline info', text: state.network.plain }),
    el('p', { class: 'pline info', text: state.network.asks }));
}
// Turning it on: with the password it already has, or with a suggested one to accept or decline.
async function lanStart(p) {
  if (p.local.password) return lanTurnOn(p, {});
  const r = await act('lan-suggest', p.pid, { port: p.port });
  if (r) setLanAsk(p.id, r.password);
}
async function lanTurnOn(p, extra) {
  lanAsk.delete(p.id);
  const chosen = lanFor.get(p.id);
  lanFor.delete(p.id);
  const r = await act('lan-on', p.pid, { port: p.port, ...(chosen == null ? {} : { for: chosen }), ...extra });
  if (r) { toast(r.message); if (extra.password) lanSeen.set(p.id, extra.password); }
  poll();
}
async function lanPassword(p, change) {
  const r = await act('lan-password', p.pid, { port: p.port, ...change });
  if (r) { toast(r.message); if (r.password) lanSeen.set(p.id, r.password); else lanSeen.delete(p.id); }
  poll();
}
async function lanChange(p) {
  const typed = await askText(`Password for ${p.local.name}.local`, 'At least 8 characters. Everyone who is signed in signs in again.', '', 'Change');
  if (typed != null) lanPassword(p, { password: typed });
}
async function renameOnNetwork(p) {
  const name = await askText(`Rename ${p.local.name}.local`,
    'Its name for other devices on this network. Lowercase letters, numbers and hyphens, up to 40. Leave it empty to use its .localhost name.', p.local.name, 'Rename');
  if (name == null) return;
  const r = await act('lan-rename', p.pid, { port: p.port, name });
  if (r) toast(r.message);
  qrCache.delete('name' + p.port);
  poll();
}

function qrBox(port, kind) {
  const box = el('div', { class: 'qr', title: 'Scan with your phone camera' });
  const draw = (rows) => box.replaceChildren(qrSvg(rows, kind === 'name' ? 'QR code of its name on the network' : kind === 'lan' ? 'QR code of the network link' : 'QR code of the public link'));
  const key = (kind || 'public') + port;
  if (qrCache.has(key)) draw(qrCache.get(key));
  else api('/api/qr?port=' + port + (kind ? '&kind=' + kind : '')).then((d) => { qrCache.set(key, d.rows); draw(d.rows); }).catch((e) => toast(e.message));
  return box;
}
function setShare(id, v) { if (v) sharing.set(id, v); else sharing.delete(id); render(); }
function askShare(p) {
  if (!state.share.available) return setShare(p.id, { kind: 'hint', text: state.share.hint, command: state.share.command });
  const entry = { kind: 'confirm', text: `Anyone with the link can open ${p.project || p.app || p.name} on port ${p.port}. For how long?` };
  setShare(p.id, entry);
  setTimeout(() => { if (sharing.get(p.id) === entry) setShare(p.id, null); }, 15000);
}
async function startShare(p, seconds) {
  setShare(p.id, null);
  const r = await act('share', p.pid, { port: p.port, for: seconds });
  if (r && r.result === 'unavailable') setShare(p.id, { kind: 'hint', text: r.message, command: state.share.command });
  poll();
}
async function stopShare(p) {
  const r = await act('unshare', p.pid, { port: p.port });
  if (r) toast(r.message);
  qrShown.delete(p.port);
  qrCache.delete('public' + p.port);
  poll();
}
async function copyText(text) {
  try { await navigator.clipboard.writeText(text); toast('Copied ' + text); }
  catch (e) { toast('Copy failed; select the text instead.'); }
}

function statusPill(pressure) {
  const [cls, label] = { normal: ['good', 'Pressure normal'], elevated: ['warning', 'Pressure elevated'], critical: ['critical', 'Pressure critical'] }[pressure] || ['good', 'Pressure ' + pressure];
  return el('span', { class: 'status ' + cls }, el('i', { 'aria-hidden': 'true' }), label);
}

function sparkline(values) {
  const NS = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(NS, 'svg');
  svg.setAttribute('viewBox', '0 0 200 28'); svg.setAttribute('preserveAspectRatio', 'none'); svg.setAttribute('aria-hidden', 'true');
  const lo = Math.min(...values), hi = Math.max(...values), span = Math.max(1, hi - lo);
  const pts = values.map((v, i) => [i / (values.length - 1) * 200, 24 - (v - lo) / span * 20]);
  const line = document.createElementNS(NS, 'polyline');
  line.setAttribute('points', pts.map((p) => p.join(',')).join(' '));
  line.setAttribute('fill', 'none'); line.setAttribute('stroke', 'var(--seq)'); line.setAttribute('stroke-width', '2');
  line.setAttribute('stroke-linejoin', 'round'); line.setAttribute('stroke-linecap', 'round'); line.setAttribute('vector-effect', 'non-scaling-stroke');
  svg.append(line);
  return svg;
}

function renderMac() {
  const m = state.memory, v = state.verdict, apps = state.apps.slice(0, 6);
  const shape = JSON.stringify([v.headline, bytes(m.used), bytes(m.swapUsed), bytes(m.swapTotal), m.pressure, swapHist.length > 1 ? swapHist.slice(-20).map(bytes) : 0,
    apps.map((a) => [a.id, bytes(a.memory), a.count, a.canQuit, busy.has(a.pid)])]);
  swap('mac', shape, () => {
    const parts = [['Apps', m.app, 'var(--seg-1)'], ['Wired', m.wired, 'var(--seg-2)'], ['Compressed', m.compressed, 'var(--seg-3)'], ['Cached files', m.cached, 'var(--seg-4)'], ['Free', m.free, 'var(--seg-free)']];
    const biggest = state.apps.find((a) => a.canQuit);
    const action = !biggest ? null : v.level === 'good'
      ? `Plenty of room. The biggest app is ${biggest.name} at ${bytes(biggest.memory)}.`
      : `Quitting ${biggest.name} would free about ${bytes(biggest.memory)}.`;
    const recent = swapHist.slice(-20);
    const memPanel = el('div', { class: 'panel' },
      el('div', { class: 'mac-head' }, statusPill(m.pressure), el('p', { class: 'verdict', text: v.headline })),
      el('p', { class: 'mac-stat' }, el('b', { text: bytes(m.used) }), `of ${bytes(m.physical)} in use`),
      el('div', {},
        el('div', { class: 'comp', role: 'img', 'aria-label': parts.map(([n, val]) => `${n} ${bytes(val)}`).join(', ') },
          parts.map(([n, val, c]) => el('i', { title: `${n}: ${bytes(val)}`, style: { 'flex-grow': String(Math.max(val, 1)), 'flex-basis': '0', background: c } }))),
        el('div', { class: 'legend-grid', style: { 'margin-top': '10px' } },
          parts.map(([n, val, c]) => el('span', {}, el('i', { class: 'sw', style: { background: c } }), n, el('b', { text: bytes(val) }))))),
      el('div', {},
        el('div', { class: 'meter-head' }, el('span', { text: 'Swap' }), el('b', { text: `${bytes(m.swapUsed)} of ${bytes(m.swapTotal)}` })),
        el('div', { class: 'meter' + (m.swapHeavy ? ' heavy' : ''), title: m.swapHeavy ? 'More than half your RAM is parked on disk' : 'Swap in use' },
          el('i', { style: { width: Math.min(100, m.swapUsed / Math.max(1, m.swapTotal) * 100).toFixed(1) + '%' } })),
        recent.length > 1 ? el('div', { class: 'spark', title: 'Swap in use, sampled each time this page refreshed' }, sparkline(recent), el('span', { text: `last ${recent.length} checks` })) : null),
      action ? el('p', { class: 'action', text: action }) : null);
    const top = Math.max(1, ...apps.map((a) => a.memory));
    const appPanel = el('div', { class: 'panel' },
      el('div', {}, el('h3', { text: 'Biggest apps' }), el('p', { class: 'sub', text: 'Real memory, the number Activity Monitor shows. Helpers count toward their app.' })),
      el('ul', { class: 'apps' }, apps.map((a) => {
        const tip = `${a.name} · ${plural(a.count, 'process', 'processes')} · ${bytes(a.memory)}${a.folder ? ' · ' + a.folder : ''}`;
        return el('li', { title: tip },
          el('span', { class: 'nm' }, a.name, a.count > 1 ? el('small', { text: plural(a.count, 'process', 'processes') }) : null),
          el('span', { class: 'track' }, el('i', { class: 'fill', style: { width: (a.memory / top * 100).toFixed(1) + '%' } })),
          el('span', { class: 'val', text: bytes(a.memory) }),
          el('span', { class: 'slot' }, a.canQuit
            ? (busy.has(a.pid) ? el('span', { class: 'busy' }, el('i', { class: 'spinner' }))
              : el('button', { class: 'pl kill', text: 'quit', onclick: () => quitProcess(a.pid, a.name, `${a.name} is using ${bytes(a.memory)}${a.count > 1 ? ' across ' + a.count + ' processes' : ''}. It closes the normal way and may ask you to save your work.${a.quitNote ? ' ' + a.quitNote : ''}`, 'apps') }))
            : null));
      })));
    return [memPanel, appPanel];
  });
}

// ---------- actions ----------
const dlg = $('dlg');
function ask(title, body, yes, danger = true) {
  $('dlg-title').textContent = title;
  $('dlg-body').textContent = body;
  $('dlg-yes').textContent = yes;
  $('dlg-yes').className = danger ? 'btn danger' : 'btn primary';
  return new Promise((resolve) => {
    dlg.addEventListener('close', () => resolve(dlg.returnValue === 'yes'), { once: true });
    dlg.returnValue = 'no';
    dlg.showModal();
    $('dlg-no').focus();
  });
}

// The same dialog with a text field: resolves to what was typed, or null when cancelled.
function askText(title, body, value, yes) {
  const input = $('dlg-input');
  $('dlg-title').textContent = title;
  $('dlg-body').textContent = body;
  $('dlg-yes').textContent = yes;
  $('dlg-yes').className = 'btn primary';
  input.value = value;
  input.hidden = false;
  return new Promise((resolve) => {
    dlg.addEventListener('close', () => { input.hidden = true; resolve(dlg.returnValue === 'yes' ? input.value : null); }, { once: true });
    dlg.returnValue = 'no';
    dlg.showModal();
    input.select();
  });
}
// Enter in the field means yes (the form's default button is Cancel).
$('dlg-input').addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); dlg.close('yes'); } });

// A project's name, the part before .localhost. The app checks it and says what's wrong.
async function rename(p) {
  const name = await askText(`Rename ${p.hostName}.localhost`,
    'Lowercase letters, numbers and hyphens, up to 40. Leave it empty to go back to the automatic name.', p.hostName, 'Rename');
  if (name == null) return;
  const r = await act('rename', p.pid, { name });
  if (r) toast(r.message);
  poll();
}

let toastTimer = null;
function toast(text) {
  const t = $('toast');
  t.textContent = text;
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, 4200);
}

async function act(op, pid, extra) {
  try { return await api('/api/action', { op, pid, ...(extra || {}) }); }
  catch (e) { toast(e.message); return null; }
}

// `from` says where the quit was asked for: 'apps' is the list of apps, the one place Docker Desktop may be quit from.
async function quitProcess(pid, name, body, from) {
  if (await ask(`Quit ${name}?`, body, 'Quit')) await run('quit', pid, name, from);
}

async function run(op, pid, label, from) {
  busy.add(pid); render();
  const r = await act(op, pid, from ? { from } : null);
  busy.delete(pid);
  if (r && r.result === 'still_running') {
    if (await ask(`${label} is still running`, r.message, 'Force stop')) return run('force', pid, label);
  } else if (r && r.result === 'not_permitted') {
    if (await ask(`${label} belongs to another user`, r.message + ' macOS asks for the password in its own window; __APP__ never sees it.', 'Use administrator password…', false)) return run('admin', pid, label);
  } else if (r && r.result !== 'cancelled') {
    toast(r.message);
  }
  poll();
}

async function copy(p) {
  try { await navigator.clipboard.writeText(address(p)); toast('Copied ' + address(p)); }
  catch (e) { const r = await act('copy', p.pid); if (r) toast(r.message); }
}

// ---------- controls ----------
for (const b of document.querySelectorAll('[data-group]')) {
  b.addEventListener('click', () => { group = b.dataset.group; if (state) { state.settings.grouping = group; render(); } saveSettings({ grouping: group }); });
}
// Appearance: the page's own setting (the menu has its own). The server already put it on <html> for the first paint.
function applyTheme(t) {
  t = ['light', 'dark'].includes(t) ? t : 'auto';
  if (document.documentElement.dataset.theme !== t) document.documentElement.dataset.theme = t;
  for (const b of document.querySelectorAll('[data-appearance]')) b.setAttribute('aria-pressed', String(b.dataset.appearance === t));
}
applyTheme(document.documentElement.dataset.theme);
for (const b of document.querySelectorAll('[data-appearance]')) {
  b.addEventListener('click', () => { const t = b.dataset.appearance; applyTheme(t); if (state) state.settings.appearance = t; saveSettings({ appearance: t }); });
}
async function saveSettings(change) {
  await act('settings', 0, change);
  poll();
}
$('show-system').addEventListener('change', (e) => saveSettings({ showSystem: e.target.checked }));
$('only-servers').addEventListener('change', (e) => saveSettings({ onlyServers: e.target.checked }));
for (const id of ['rmin', 'rmax']) $(id).addEventListener('change', () => {
  const lo = parseInt($('rmin').value, 10), hi = parseInt($('rmax').value, 10);
  if (lo >= 1 && hi >= 1) saveSettings({ minPort: lo, maxPort: hi });
});
$('q').addEventListener('input', (e) => { query = e.target.value.trim(); if (state) render(); });
$('show-dock').addEventListener('change', (e) => saveSettings({ showInDock: e.target.checked }));
$('login-item').addEventListener('change', async (e) => {
  const r = await act('login-item', 0, { enabled: e.target.checked });
  if (r) toast(r.message);
  poll();
});
window.addEventListener('resize', () => { if (state) renderHero(state.ports.filter((p) => !p.hidden)); });
$('refresh').addEventListener('click', () => poll());
// Update now: asked first, and only ever from this click.
$('update-now').addEventListener('click', async () => {
  const u = state && state.update;
  if (!u || !u.canUpdate || u.updating) return;
  if (!await ask(`Update __app__ to ${u.latest}?`, u.question || '', 'Update', false)) return;
  try { const r = await api('/api/action', { op: 'update-now' }); toast(r.message); } catch (e) { toast(e.message); }
  poll();
});

redeem().then(poll);
</script>
</body>
</html>
"""#
}
