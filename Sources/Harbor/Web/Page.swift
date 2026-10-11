// The harbor page, served by WebServer at http://127.0.0.1:<port>/#<token>.
// Every value from the app is rendered with textContent; nothing is parsed as HTML.
enum Page {
    /// The page with the app's name filled in (see AppInfo).
    static let html = template
        .replacingOccurrences(of: "__APP__", with: AppInfo.name)
        .replacingOccurrences(of: "__app__", with: AppInfo.name.lowercased())

    private static let template = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="light dark">
<title>__APP__</title>
<style>
  :root {
    color-scheme: light dark;
    --ink: #0b0b0c;
    --on-ink: #f3f3f1;
    --on-ink-2: #a2a5ac;
    --on-ink-3: #6d7078;
    --ink-line: #24252a;
    --signal: #a7b4ff;
    --live: #46d39a;
    --bg: #ffffff;
    --panel: #f6f6f4;
    --panel-2: #efefec;
    --line: #e5e5e1;
    --text: #0b0b0c;
    --text-2: #45474d;
    --muted: #6f727a;
    --danger: #d4392b;
    --danger-soft: #fbeae8;
    --warn: #a35a00;
    --warn-soft: #fbf1e3;
    --focus: #4a63f5;
    --c-ports: #6c7cff;
    --c-mac: #18a47c;
    --f-display: -apple-system, BlinkMacSystemFont, "SF Pro Display", system-ui, sans-serif;
    --f-body: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
    --f-mono: ui-monospace, "SF Mono", SFMono-Regular, Menlo, monospace;
    --gutter: clamp(16px, 3.2vw, 36px);
    --ease: cubic-bezier(.2, .7, .1, 1);
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #0e0e10;
      --panel: #16161a;
      --panel-2: #1d1d22;
      --line: #27272d;
      --text: #f2f2f0;
      --text-2: #c7c9cf;
      --muted: #8d9099;
      --danger: #ff5d4d;
      --danger-soft: #2a1513;
      --warn: #f2a54a;
      --warn-soft: #261c10;
      --focus: #a7b4ff;
      --c-ports: #a7b4ff;
      --c-mac: #46d39a;
    }
  }
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
  .hero-lede .warn { color: #f5b25c; }
  .map { margin-top: clamp(26px, 4vw, 44px); }
  .ticks { display: flex; align-items: flex-end; gap: 3px; height: 46px; }
  .ticks i {
    flex: 1 1 0; min-width: 0; height: 22%; border-radius: 1px; background: #2c2e33;
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
  .psub { color: var(--muted); font-size: 13px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .pacts { display: flex; gap: 6px; align-items: center; }
  .pl {
    font: 500 12.5px/1 var(--f-body); padding: 7px 12px; border-radius: 999px; border: 0; background: var(--panel-2);
    color: var(--text-2); cursor: pointer; text-decoration: none; white-space: nowrap; transition: background-color .15s, color .15s;
  }
  .card .pl, .group .pl { background: var(--bg); }
  .pl:hover { background: var(--line); color: var(--text); }
  .pl.kill:hover { background: var(--danger-soft); color: var(--danger); }
  .pl.confirm, .pl.force { background: var(--danger); color: #fff; }
  .pl.confirm:hover, .pl.force:hover { background: var(--danger); color: #fff; filter: brightness(1.08); }
  .pl.admin { background: var(--text); color: var(--bg); }
  .pl.admin:hover { background: var(--text); color: var(--bg); }
  .pline { padding: 0 18px 12px 128px; font-size: 13px; color: var(--danger); }
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

  /* ---------- this mac (extras) ---------- */
  .mac { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1.2fr); gap: 16px; }
  .panel { background: var(--panel); border-radius: 14px; padding: 18px; border-top: 3px solid var(--c-mac); }
  .panel h3 { font: 700 15px/1.3 var(--f-body); margin-bottom: 4px; display: flex; gap: 8px; align-items: center; }
  .panel .dot { width: 8px; height: 8px; }
  .panel p.note { color: var(--muted); font-size: 13.5px; }
  .stack { display: flex; height: 12px; border-radius: 3px; overflow: hidden; gap: 2px; margin: 16px 0 10px; }
  .stack i { display: block; min-width: 2px; }
  .keys { display: flex; flex-wrap: wrap; gap: 4px 16px; color: var(--muted); font-size: 12.5px; }
  .keys span { display: inline-flex; align-items: center; gap: 6px; }
  .keys b { color: var(--text); font-weight: 600; }
  .bars li { display: grid; grid-template-columns: minmax(0, 9em) minmax(0, 1fr) 4.6em auto; gap: 12px; align-items: center; padding: 7px 0; }
  .bars .nm { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-weight: 600; font-size: 14px; }
  .bars .track { height: 10px; border-radius: 2px; background: var(--panel-2); overflow: hidden; }
  .bars .fill { display: block; height: 100%; border-radius: 2px; transition: width .45s var(--ease); }
  .bars .val { font: 600 12.5px/1 var(--f-mono); text-align: right; }

  /* ---------- floating pill ---------- */
  .pill {
    position: fixed; left: 50%; bottom: max(18px, env(safe-area-inset-bottom)); transform: translateX(-50%);
    display: flex; align-items: center; gap: 12px; padding: 7px 8px 7px 16px; border-radius: 999px;
    background: #111114f2; color: var(--on-ink); box-shadow: 0 10px 30px #00000038, inset 0 0 0 1px #ffffff14;
    width: min(620px, calc(100vw - 24px)); z-index: 5; --focus: var(--signal);
  }
  .pill .status { display: inline-flex; align-items: center; gap: 8px; color: var(--on-ink-2); white-space: nowrap; }
  .pill input {
    flex: 1; min-width: 0; background: #ffffff12; border: 1px solid #ffffff1c; border-radius: 999px;
    padding: 8px 14px; color: var(--on-ink); outline: none; font-size: 14px;
  }
  .pill input::placeholder { color: var(--on-ink-3); }
  .pill input:focus { border-color: var(--signal); }
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
  dialog p { color: var(--text-2); font-size: 14px; margin-top: 8px; overflow-wrap: anywhere; }
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
    .pport { font-size: 19px; }
    .pacts { justify-content: flex-end; }
    .pline, .pdetails { padding-left: 18px; }
    .pdetails { grid-template-columns: 5.5em minmax(0, 1fr) auto; }
    .bars li { grid-template-columns: minmax(0, 7em) minmax(0, 1fr) 4.2em; }
    .bars li .btn { grid-column: 1 / -1; justify-self: start; }
    .nav-meta { display: none; }
  }
  @media (prefers-reduced-motion: reduce) { * { transition: none !important; animation: none !important; } }
</style>
</head>
<body>
<header class="top">
  <div class="wrap">
    <nav class="nav">
      <span class="logo">
        <svg viewBox="0 0 26 18" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M1 6c2.5-2.4 4.5-2.4 7 0s4.5 2.4 7 0 4.5-2.4 7 0"/><path d="M1 13c2.5-2.4 4.5-2.4 7 0s4.5 2.4 7 0 4.5-2.4 7 0"/></svg>
        __app__
      </span>
      <span class="nav-meta mono">Ports on this Mac</span>
    </nav>
    <div class="strip mono">
      <span><i class="dot" id="live-dot"></i><span id="st-live">Connecting</span></span>
      <span id="st-scan">127.0.0.1 only</span>
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
<div class="offline" id="offline" hidden><div class="wrap">__APP__ isn't answering. Open it from the menu bar or Applications, then reload this page.</div></div>

<main class="wrap">
  <section id="s-ports" style="--sec: var(--c-ports)">
    <div class="sec-head">
      <div>
        <div class="sec-title"><span class="sec-num">01</span><h2 class="display">Ports</h2></div>
        <p class="sec-sub" id="ports-sub">Open, copy or kill each one. Click a row for details.</p>
      </div>
      <div class="controls">
        <div class="seg" role="group" aria-label="Group ports">
          <button type="button" data-group="project" aria-pressed="true">Project</button>
          <button type="button" data-group="category" aria-pressed="false">Category</button>
          <button type="button" data-group="port" aria-pressed="false">Flat</button>
        </div>
        <span class="range" title="Ports outside this range are hidden, like Manfath's visible range.">Ports
          <input type="number" id="rmin" min="1" max="65535" aria-label="Lowest port shown"> –
          <input type="number" id="rmax" min="1" max="65535" aria-label="Highest port shown"></span>
        <label class="check"><input type="checkbox" id="only-servers"> Servers only</label>
        <label class="check"><input type="checkbox" id="show-system"> <span id="show-system-label">macOS services</span></label>
      </div>
    </div>
    <div class="cards" id="cards"></div>
    <p class="hidden-note" id="hidden-note"></p>
  </section>

  <section id="s-mac" style="--sec: var(--c-mac)">
    <div class="sec-head">
      <div>
        <div class="sec-title"><span class="sec-num">02</span><h2 class="display">This Mac</h2></div>
        <p class="sec-sub">Memory, and the apps holding most of it.</p>
      </div>
      <label class="check"><input type="checkbox" id="login-item"> Open __APP__ at login</label>
    </div>
    <div class="mac" id="mac"></div>
  </section>
</main>

<div class="pill" role="search">
  <span class="status mono"><i class="dot" id="pill-dot"></i><span id="pill-status">Live</span></span>
  <input id="q" type="search" placeholder="Filter by port, project or PID" autocomplete="off" spellcheck="false" aria-label="Filter ports">
</div>
<div class="toast" id="toast" role="status" hidden></div>

<dialog id="dlg">
  <form method="dialog">
    <h3 id="dlg-title"></h3>
    <p id="dlg-body"></p>
    <div class="dlg-actions">
      <button class="btn" value="no" id="dlg-no">Cancel</button>
      <button class="btn danger" value="yes" id="dlg-yes"></button>
    </div>
  </form>
</dialog>

<script>
'use strict';
const token = location.hash.slice(1);
const $ = (id) => document.getElementById(id);
const PALETTE = ['#4f8cf7', '#19a77d', '#9a84f4', '#de5a88', '#cf9214', '#16a6c2', '#e8743f', '#6b8f2a'];
const POLL_MS = 3000;
let state = null, timer = null, group = 'project', query = '';
const phase = new Map();   // row id -> { kind: confirm|working|force|admin|msg, text }
const opened = new Set();  // expanded row ids
const busy = new Set();
const sig = {};

function store(key, value) { try { localStorage.setItem(key, value); } catch (e) {} }
function load(key) { try { return localStorage.getItem(key); } catch (e) { return null; } }
group = ['project', 'category', 'port'].includes(load('harbor.group')) ? load('harbor.group') : 'project';

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

// ---------- API ----------
async function api(path, body) {
  const opts = { headers: { 'X-Token': token }, cache: 'no-store' };
  if (body) { opts.method = 'POST'; opts.headers['Content-Type'] = 'application/json'; opts.body = JSON.stringify(body); }
  const reply = await fetch(path, opts);
  const data = await reply.json().catch(() => ({}));
  if (!reply.ok) throw new Error(data.error || ('HTTP ' + reply.status));
  return data;
}

async function poll() {
  clearTimeout(timer);
  timer = null;
  if (document.visibilityState !== 'visible') return;
  try {
    state = await api('/api/state');
    $('offline').hidden = true;
    render();
  } catch (e) {
    $('offline').hidden = false;
    setLive(false, 'Not answering');
  }
  if (document.visibilityState === 'visible') timer = setTimeout(poll, POLL_MS);
}
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
    [p.name, p.title, p.framework, p.project, p.command, p.app].some((v) => v && v.toLowerCase().includes(q)));
}

function groupKey(p) { return p.projectPath ? 'p:' + p.projectPath : 'a:' + (p.app || p.name); }

function groups(ports) {
  const map = new Map();
  for (const p of ports) {
    const key = groupKey(p);
    if (!map.has(key)) map.set(key, {
      key, rows: [], rank: p.isProject ? 0 : p.projectPath ? 1 : 2,
      title: p.project || p.app || p.name, path: p.projectPath, folder: p.projectPath ? p.folder : null,
    });
    map.get(key).rows.push(p);
  }
  return [...map.values()]
    .map((g) => ({ ...g, rows: g.rows.sort((a, b) => a.port - b.port) }))
    .sort((a, b) => a.rank - b.rank || a.title.localeCompare(b.title, undefined, { sensitivity: 'base' }));
}

function render() {
  const all = state.ports.filter((p) => !p.hidden);
  const ports = visiblePorts();
  setLive(true, `Updated ${Math.round(state.scannedAgo)}s ago`);
  $('st-scan').textContent = `127.0.0.1 only · scanned in ${state.scanMs.toFixed(0)} ms · refreshes every 3 s while open`;
  renderHero(all);
  renderAlarm();
  renderNotices();
  renderPorts(ports, all);
  renderMac();
  $('login-item').checked = !!state.loginItem;
}

function renderHero(all) {
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
  const sigText = first + '|' + exposed;
  if (sig.lede !== sigText) {
    sig.lede = sigText;
    lede.replaceChildren(first);
    if (exposed) lede.append(' ', el('span', { class: 'warn', text: `${plural(exposed, 'port is', 'ports are')} reachable from your network.` }));
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
      out.push(ps ? el('i', { class: 'on', title: ps.map((p) => `:${p.port} ${p.title}`).join('\n'), style: { 'background-color': colour(groupKey(ps[0])) } }) : el('i'));
    }
    return out;
  });
  const marks = n < 60 ? [1000, 3000, 5000, 10000, 20000, 40000] : [1000, 2000, 3000, 5000, 8000, 10000, 20000, 40000];
  swap('axis', String(n), () => marks.map((v) =>
    el('span', { text: v >= 1000 ? (v / 1000) + 'k' : String(v), style: { left: ((Math.log(v) - lo) / (hi - lo) * 100).toFixed(2) + '%' } })));
  const gs2 = groups(all).slice(0, window.innerWidth < 640 ? 4 : 6);
  swap('legend', JSON.stringify(gs2.map((g) => [g.key, g.rows.length])), () => gs2.map((g) =>
    el('li', {}, el('i', { class: 'sw', style: { background: colour(g.key) } }), el('b', { text: g.title }), ' ' + g.rows.map((p) => ':' + p.port).join(' '))));
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
  for (const b of document.querySelectorAll('.seg button')) b.setAttribute('aria-pressed', String(b.dataset.group === group));

  let model;
  if (group === 'project') model = groups(ports).map((g) => ({ ...g, kind: 'card' }));
  else if (group === 'category') model = CATEGORY_ORDER.map((c) => {
    const rows = ports.filter((p) => p.category === c).sort((a, b) => a.port - b.port);
    return rows.length ? { key: 'c:' + c, kind: 'section', title: rows[0].categoryTitle, rows } : null;
  }).filter(Boolean);
  else model = [{ key: 'flat', kind: 'section', title: 'All ports', rows: [...ports].sort((a, b) => a.port - b.port) }];

  const shape = model.map((g) => [g.key, g.rows.map((p) => [p.id, p.title, p.name, p.framework, p.command, p.address,
    uptime(p.uptime), bytes(p.memory), p.workers, p.busy, p.system, p.hint, phase.get(p.id), opened.has(p.id)])]);
  swap('cards', group + query + JSON.stringify(shape), () => {
    $('cards').className = group === 'project' ? 'cards' : 'stack-list';
    if (!ports.length) {
      return el('div', { class: 'empty' }, el('b', { text: query ? 'No matches' : 'No services listening' }),
        query ? 'Try a port number, a project name or a PID.' : "Start a dev server and it'll show up here within a few seconds.");
    }
    return model.map((g) => g.kind === 'card' ? card(g) : section(g));
  });
}

function card(g) {
  const frameworks = [...new Set(g.rows.map((p) => p.framework).filter(Boolean))];
  const head = el('div', { class: 'card-head' },
    el('div', { class: 'card-title' },
      el('h3', { text: g.title }),
      el('p', { class: 'card-path mono', text: g.path || 'App or service' }),
      frameworks.length ? el('div', { class: 'chips' }, frameworks.map((f) => el('span', { class: 'chip', text: f }))) : null),
    g.folder ? el('button', { class: 'btn quiet', text: 'Reveal', title: 'Show this folder in Finder', onclick: () => act('reveal', g.rows[0].pid) }) : null);
  return el('article', { class: 'card', style: { '--pc': colour(g.key) } },
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
  const title = showProject ? p.title : p.name;
  const facts = [showProject && p.title !== p.name ? p.name : null,
    'pid ' + p.pid + (p.workers ? ` +${p.workers}` : ''),
    p.uptime != null ? 'up ' + uptime(p.uptime) : null, p.memory != null ? bytes(p.memory) : null].filter(Boolean).join(' · ');
  const stop = (e) => e.stopPropagation();
  const pill = (text, cls, onclick, extra) => el('button', { class: 'pl ' + (cls || ''), text, onclick: (e) => { stop(e); onclick(); }, ...(extra || {}) });

  let acts;
  if (ph && ph.kind === 'working' || p.busy) acts = el('span', { class: 'busy' }, el('i', { class: 'spinner' }), 'stopping');
  else if (ph && ph.kind === 'confirm') acts = [pill('confirm?', 'confirm', () => runStop(p, 'stop')), pill('cancel', '', () => setPhase(p.id, null))];
  else if (ph && ph.kind === 'force') acts = [pill('force kill', 'force', () => runStop(p, 'force')), pill('cancel', '', () => setPhase(p.id, null))];
  else if (ph && ph.kind === 'admin') acts = [pill('admin password…', 'admin', () => runStop(p, 'admin')), pill('cancel', '', () => setPhase(p.id, null))];
  else acts = [
    el('a', { class: 'pl', href: safeUrl(p.url), target: '_blank', rel: 'noopener noreferrer', text: 'open', title: 'Open ' + p.url, onclick: stop }),
    pill('copy', '', () => copy(p), { title: 'Copy ' + p.url }),
    p.system ? null : pill('kill', 'kill', () => armKill(p), { title: `Kill PID ${p.pid}` }),
  ];

  const isOpen = opened.has(p.id);
  const li = el('li', { class: isOpen ? 'open' : '' },
    el('div', { class: 'prow', role: 'button', tabindex: '0', 'aria-expanded': String(isOpen),
      onclick: () => toggle(p.id), onkeydown: (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggle(p.id); } } },
      el('div', { class: 'pmain' },
        el('span', { class: 'pport', text: ':' + p.port }),
        el('div', { class: 'ptext' },
          el('div', { class: 'ptitle' }, el('span', { class: 't', text: title }),
            p.framework && p.framework !== title ? el('span', { class: 'tag', text: p.framework }) : null,
            p.exposed ? el('span', { class: 'tag warn', text: p.address, title: 'Other devices on your network can reach this port.' }) : null),
          el('div', { class: 'psub', text: facts }))),
      el('div', { class: 'pacts' }, acts)),
    ph && ph.text ? el('p', { class: 'pline' + (ph.kind === 'msg' ? ' info' : '') , text: ph.text }) : null,
    isOpen ? details(p) : null);
  return li;
}

function details(p) {
  const items = [];
  const add = (label, value, action) => items.push(el('dt', { text: label }), el('dd', { text: value }), action || el('span'));
  if (p.folder) add('Folder', p.folder, el('button', { class: 'pl', text: 'reveal', onclick: () => act('reveal', p.pid) }));
  if (p.command) add('Command', p.command);
  add('Address', p.address);
  add('URL', p.url, el('button', { class: 'pl', text: 'copy', onclick: () => copy(p) }));
  if (p.memory != null) add('Memory', bytes(p.memory));
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

function safeUrl(url) { return /^http:\/\/(localhost|127\.0\.0\.1|\[[0-9a-f:]+\]|[0-9.]+):\d+$/i.test(url) ? url : '#'; }

function renderMac() {
  const m = state.memory, v = state.verdict, apps = state.apps;
  const shape = JSON.stringify([v.headline, bytes(m.used), bytes(m.swapUsed), m.pressure,
    apps.map((a) => [a.id, bytes(a.memory), a.canQuit, busy.has(a.pid)])]);
  swap('mac', shape, () => {
    const parts = [['Apps', m.app, '#4f8cf7'], ['Wired', m.wired, '#cf9214'], ['Compressed', m.compressed, '#9a84f4'],
      ['Cached files', m.cached, '#16a6c2'], ['Free', m.free, 'var(--line)']];
    const lvl = { good: 'var(--live)', warn: '#e39a2f', bad: 'var(--danger)' }[v.level];
    const memPanel = el('div', { class: 'panel' },
      el('h3', {}, el('i', { class: 'dot', style: { background: lvl } }), v.headline),
      el('p', { class: 'note', text: `${bytes(m.used)} of ${bytes(m.physical)} in use · ${bytes(m.swapUsed)} of swap · pressure ${m.pressure}.` }),
      el('div', { class: 'stack', title: 'How the RAM is used' }, parts.map(([name, val, c]) =>
        el('i', { title: `${name}: ${bytes(val)}`, style: { width: (val / m.physical * 100).toFixed(2) + '%', background: c } }))),
      el('div', { class: 'keys' }, parts.map(([name, val, c]) => el('span', {}, el('i', { class: 'sw', style: { background: c } }), name, el('b', { text: bytes(val) })))));
    const top = Math.max(1, ...apps.map((a) => a.memory));
    const appPanel = el('div', { class: 'panel' },
      el('h3', { text: 'Biggest apps' }),
      el('p', { class: 'note', text: 'Real memory, the number Activity Monitor shows.' }),
      el('ul', { class: 'bars' }, apps.slice(0, 6).map((a) => el('li', {},
        el('span', { class: 'nm', text: a.name, title: a.folder ? `${a.name} · ${a.folder}` : a.name }),
        el('span', { class: 'track' }, el('i', { class: 'fill', style: { width: (a.memory / top * 100).toFixed(1) + '%', background: colour('app' + a.name) } })),
        el('span', { class: 'val', text: bytes(a.memory) }),
        a.canQuit ? (busy.has(a.pid) ? el('span', { class: 'busy' }, el('i', { class: 'spinner' }))
          : el('button', { class: 'btn quiet', text: 'Quit', onclick: () => quitProcess(a.pid, a.name, `${a.name} is using ${bytes(a.memory)}${a.count > 1 ? ' across ' + a.count + ' processes' : ''}. It closes the normal way and may ask you to save your work.`) }))
          : el('span')))));
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

async function quitProcess(pid, name, body) {
  if (await ask(`Quit ${name}?`, body, 'Quit')) await run('quit', pid, name);
}

async function run(op, pid, label) {
  busy.add(pid); render();
  const r = await act(op, pid);
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
  try { await navigator.clipboard.writeText(p.url); toast('Copied ' + p.url); }
  catch (e) { const r = await act('copy', p.pid); if (r) toast(r.message); }
}

// ---------- controls ----------
for (const b of document.querySelectorAll('.seg button')) {
  b.addEventListener('click', () => { group = b.dataset.group; store('harbor.group', group); if (state) render(); });
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
$('login-item').addEventListener('change', async (e) => {
  const r = await act('login-item', 0, { enabled: e.target.checked });
  if (r) toast(r.message);
  poll();
});
window.addEventListener('resize', () => { if (state) renderHero(state.ports.filter((p) => !p.hidden)); });

if (!token) { $('offline').hidden = false; setLive(false, 'No token'); }
else poll();
</script>
</body>
</html>
"""#
}
