// Three candidate looks for the harbor page, served at /?look=a|b|c while the
// default page stays as it is. Same data, rows, pills and safety rules as the
// default page; only the frame differs. All values render via textContent.
enum PageLooks {
    static let html = template
        .replacingOccurrences(of: "__APP__", with: AppInfo.name)
        .replacingOccurrences(of: "__app__", with: AppInfo.name.lowercased())

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
  /* ---------- shared: pills and tags match the menu bar ---------- */
  :root[data-theme="light"] { color-scheme: light; }
  :root {
    color-scheme: light dark;
    --pill: #e3e3e5; --pill-ink: #2c2c2e; --pill-hover: #d6d6d9;
    --open-bg: #dbe7fb; --open-ink: #0a4fb0;
    --share-bg: #d4f0e4; --share-ink: #0b6b4b;
    --kill-bg: #f9dedb; --kill-ink: #b3261e;
    --red: #c5221f; --shared: #0f7f5f; --shared-ink: #ffffff; --admin: #0a5bd3;
    --warn-bg: #fdf0dc; --warn-ink: #8a4b00;
    --f-body: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
    --f-mono: ui-monospace, "SF Mono", SFMono-Regular, Menlo, monospace;
  }
  \#(Page.dark("color-scheme: dark; --pill: #3d3d40; --pill-ink: #e8e8ea; --pill-hover: #4a4a4e; --open-bg: #1f3352; --open-ink: #a9c8ff; --share-bg: #173b2e; --share-ink: #86e3bb; --kill-bg: #4a201c; --kill-ink: #ff9a90; --shared: #46d39a; --shared-ink: #0e0e10; --warn-bg: #2c2112; --warn-ink: #f2b866;"))
  *, *::before, *::after { box-sizing: border-box; }
  html { -webkit-text-size-adjust: 100%; }
  body { margin: 0; font: 14px/1.45 var(--f-body); -webkit-font-smoothing: antialiased; background: var(--bg); color: var(--text); }
  h1, h2, h3, p, ul, dl { margin: 0; }
  ul { padding: 0; list-style: none; }
  button, input { font: inherit; color: inherit; }
  [hidden] { display: none !important; }
  :focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; border-radius: 6px; }

  .pl {
    font: 500 12.5px/1 var(--f-body); padding: 6px 11px; border-radius: 999px; border: 0; cursor: pointer;
    background: var(--pill); color: var(--pill-ink); text-decoration: none; white-space: nowrap;
  }
  .pl:hover { background: var(--pill-hover); }
  .pl.open { background: var(--open-bg); color: var(--open-ink); }
  .pl.share { background: var(--share-bg); color: var(--share-ink); }
  .pl.open:hover, .pl.share:hover { filter: brightness(.96); }
  .pl.kill:hover { background: var(--kill-bg); color: var(--kill-ink); }
  .pl.confirm, .pl.force { background: var(--red); color: #fff; }
  .pl.go { background: var(--shared); color: var(--shared-ink); }
  .pl.admin { background: var(--admin); color: #fff; }
  .tag { font: 600 11px/1 var(--f-body); padding: 3px 6px; border-radius: 5px; border: 1px solid var(--line); color: var(--muted); white-space: nowrap; }
  .tag.warn { border-color: transparent; background: var(--warn-bg); color: var(--warn-ink); }
  .tag.shared { border-color: transparent; background: var(--shared); color: var(--shared-ink); }
  .tag.macos { border-color: transparent; background: var(--pill); color: var(--pill-ink); }
  .chip { width: 10px; height: 10px; border-radius: 3px; flex: none; display: inline-block; }
  .busy { display: inline-flex; align-items: center; gap: 7px; color: var(--muted); font-size: 12.5px; }
  .spin { width: 13px; height: 13px; border-radius: 50%; border: 2px solid var(--line); border-top-color: var(--text); animation: spin .8s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }

  /* rows */
  .rows > li + li { border-top: 1px solid var(--line-2); }
  .rmain { display: grid; grid-template-columns: var(--portw, 84px) minmax(0, 1fr) auto; gap: 4px 14px; align-items: center; padding: 9px 14px; cursor: pointer; }
  .rmain:hover, .rows > li.open .rmain { background: var(--hover); }
  .pport { font: 650 15px/1.2 var(--f-mono); letter-spacing: -.01em; }
  .rtext { min-width: 0; }
  .rtitle { display: flex; align-items: center; gap: 7px; min-width: 0; font-weight: 600; }
  .rtitle .t { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .rsub { color: var(--muted); font-size: 12.5px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; display: flex; align-items: center; gap: 6px; }
  .racts { display: flex; gap: 6px; justify-content: flex-end; flex-wrap: wrap; }
  .rextra { padding: 0 14px 10px calc(14px + var(--portw, 84px) + 14px); display: grid; gap: 8px; }
  .note { font-size: 13px; color: var(--kill-ink); }
  .note.share { color: var(--warn-ink); }
  .note.info { color: var(--text-2); }
  .note code { font: 12px var(--f-mono); background: var(--pill); padding: 2px 6px; border-radius: 5px; color: var(--pill-ink); }
  .tunnel { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; font-size: 13px; color: var(--text-2); }
  .tunnel a { font: 12.5px/1.4 var(--f-mono); color: var(--share-ink); overflow-wrap: anywhere; }
  .qr { background: #fff; padding: 8px; border-radius: 8px; width: max-content; }
  .qr canvas { display: block; image-rendering: pixelated; }
  .details { display: grid; grid-template-columns: 6em minmax(0, 1fr) auto; gap: 6px 12px; align-items: baseline; font-size: 12.5px; }
  .details dt { color: var(--muted); }
  .details dd { margin: 0; font: 12.5px/1.45 var(--f-mono); color: var(--text-2); overflow-wrap: anywhere; }

  /* toolbar */
  .toolbar { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 12px; }
  .search { flex: 1 1 220px; min-width: 0; height: 32px; padding: 0 12px; border-radius: 8px; border: 1px solid var(--line); background: var(--surface); outline: none; }
  .search:focus { border-color: var(--accent); }
  .seg { display: inline-flex; background: var(--seg-bg, var(--line-2)); border-radius: 8px; padding: 2px; }
  .seg button { border: 0; background: none; padding: 5px 11px; border-radius: 6px; font-size: 12.5px; font-weight: 600; color: var(--muted); cursor: pointer; }
  .seg button[aria-pressed="true"] { background: var(--surface); color: var(--text); box-shadow: 0 1px 2px #0000001f; }
  .range { display: inline-flex; align-items: center; gap: 5px; font-size: 12.5px; color: var(--text-2); }
  .range input { width: 5.4em; height: 28px; padding: 0 7px; border-radius: 7px; border: 1px solid var(--line); background: var(--surface); font: 12.5px var(--f-mono); }
  .check { display: inline-flex; align-items: center; gap: 6px; font-size: 12.5px; color: var(--text-2); cursor: pointer; }
  .check input { width: 14px; height: 14px; margin: 0; accent-color: var(--accent); }

  .banner { padding: 10px 14px; border-radius: 10px; font-size: 13.5px; display: flex; gap: 12px; align-items: center; flex-wrap: wrap; }
  .banner p { flex: 1 1 280px; }
  .banner.alarm { background: var(--kill-bg); color: var(--kill-ink); font-weight: 600; }
  .banner.notice { background: var(--warn-bg); color: var(--warn-ink); }
  .banner.offline { background: var(--line-2); color: var(--text-2); }
  .empty { padding: 40px 16px; text-align: center; color: var(--muted); }
  .empty b { display: block; color: var(--text); font-size: 16px; margin-bottom: 4px; }
  .foot { color: var(--muted); font-size: 12px; }
  .toast {
    position: fixed; left: 50%; transform: translateX(-50%); bottom: max(16px, env(safe-area-inset-bottom));
    background: var(--surface); color: var(--text); border: 1px solid var(--line); padding: 9px 14px; border-radius: 10px;
    font-size: 13.5px; box-shadow: 0 8px 24px #00000024; max-width: min(560px, calc(100vw - 24px)); z-index: 5;
  }

  /* This Mac (kept small) */
  .mac { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1.15fr); gap: 10px 28px; }
  .mac h2 { grid-column: 1 / -1; font-size: 14px; display: flex; justify-content: space-between; align-items: center; gap: 12px; }
  .mac .mem p { color: var(--text-2); font-size: 13px; }
  .ram { display: flex; height: 8px; border-radius: 3px; overflow: hidden; gap: 2px; margin: 10px 0 8px; }
  .ram i { display: block; min-width: 2px; }
  .keys { display: flex; flex-wrap: wrap; gap: 3px 12px; font-size: 12px; color: var(--muted); }
  .keys span { display: inline-flex; align-items: center; gap: 5px; }
  .keys b { color: var(--text-2); font-weight: 600; }
  .apps li { display: grid; grid-template-columns: minmax(0, 8em) minmax(0, 1fr) 4.4em 7.2em; gap: 10px; align-items: center; padding: 3px 0; font-size: 13px; }
  .apps .nm { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-weight: 600; }
  .apps .track { height: 6px; border-radius: 2px; background: var(--line-2); overflow: hidden; }
  .apps .fill { display: block; height: 100%; background: var(--accent); border-radius: 2px; }
  .apps .val { font: 12px var(--f-mono); text-align: right; color: var(--text-2); }

  /* ================= A: dev-tool table ================= */
  body.look-a {
    --bg: #f7f7f8; --surface: #ffffff; --line: #e4e4e7; --line-2: #f1f1f3; --hover: #f7f7f9;
    --text: #18181b; --text-2: #3f3f46; --muted: #71717a; --accent: #5b5bd6;
  }
  \#(Page.dark("--bg: #0d0d0f; --surface: #161618; --line: #27272b; --line-2: #1e1e21; --hover: #1b1b1e; --text: #ededef; --text-2: #c9c9ce; --muted: #8b8b93; --accent: #8e8ef5;", "body.look-a"))
  .look-a .top { position: sticky; top: 0; z-index: 3; background: color-mix(in srgb, var(--surface) 92%, transparent); backdrop-filter: blur(8px); border-bottom: 1px solid var(--line); }
  .look-a .top-in { max-width: 1120px; margin: 0 auto; padding: 10px 20px; display: flex; align-items: center; gap: 10px; }
  .look-a .brand { display: flex; align-items: center; gap: 8px; font-weight: 650; font-size: 15px; }
  .look-a .brand svg { width: 20px; height: 20px; color: var(--accent); }
  .look-a .count { font: 600 12px/1 var(--f-mono); padding: 4px 8px; border-radius: 999px; background: var(--line-2); color: var(--text-2); }
  .look-a .status { margin-left: auto; color: var(--muted); font-size: 12.5px; display: flex; align-items: center; gap: 6px; }
  .look-a .dot { width: 7px; height: 7px; border-radius: 50%; background: #22a06b; }
  .look-a main { max-width: 1120px; margin: 0 auto; padding: 16px 20px 60px; display: grid; gap: 14px; }
  .look-a .list { background: var(--surface); border: 1px solid var(--line); border-radius: 10px; overflow: hidden; }
  .look-a .ghead { display: flex; align-items: center; gap: 9px; padding: 8px 14px; background: var(--line-2); border-top: 1px solid var(--line); font-size: 13px; }
  .look-a .grp:first-child .ghead { border-top: 0; }
  .look-a .ghead b { font-weight: 650; }
  .look-a .ghead .path { color: var(--muted); font-size: 12px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0; flex: 1; }
  .look-a .ghead .n { color: var(--muted); font: 12px var(--f-mono); }
  .look-a .ghead + .rows > li:first-child { border-top: 1px solid var(--line-2); }
  .look-a .panel { background: var(--surface); border: 1px solid var(--line); border-radius: 10px; padding: 14px; }

  /* ================= B: harbour ================= */
  body.look-b {
    --bg: #edf3f6; --surface: #ffffff; --line: #d6e3e9; --line-2: #e7eff3; --hover: #f4f9fb;
    --text: #0d2433; --text-2: #33505f; --muted: #5a7482; --accent: #0e8a87;
    --navy: #0c2b45; --navy-ink: #eaf5f9; --navy-muted: #9cc1d0; --seg-bg: #e3edf1;
  }
  \#(Page.dark("--bg: #07131b; --surface: #0e1f2a; --line: #1b3442; --line-2: #132936; --hover: #122735; --text: #e5f1f5; --text-2: #b6cfd9; --muted: #7e9cab; --accent: #3fd0c9; --navy: #051726; --seg-bg: #132936;", "body.look-b"))
  .look-b .top { background: var(--navy); color: var(--navy-ink); position: relative; overflow: hidden; }
  .look-b .top-in { max-width: 1120px; margin: 0 auto; padding: 18px 20px 30px; display: grid; gap: 6px; }
  .look-b .brand { display: flex; align-items: center; gap: 10px; font-weight: 650; font-size: 19px; }
  .look-b .brand svg { width: 24px; height: 24px; color: #5ed6cf; }
  .look-b .count { font: 600 12.5px/1 var(--f-body); padding: 5px 9px; border-radius: 999px; background: #ffffff1a; color: var(--navy-ink); }
  .look-b .status { margin-left: auto; color: var(--navy-muted); font-size: 12.5px; display: flex; align-items: center; gap: 6px; }
  .look-b .dot { width: 7px; height: 7px; border-radius: 50%; background: #5ed6cf; }
  .look-b .summary { color: var(--navy-muted); font-size: 14px; }
  .look-b .wave { position: absolute; left: 0; right: 0; bottom: 6px; width: 100%; height: 14px; color: #5ed6cf; opacity: .35; }
  .look-b main { max-width: 1120px; margin: 0 auto; padding: 18px 20px 60px; display: grid; gap: 16px; }
  .look-b .list { display: grid; gap: 14px; }
  .look-b .grp { background: var(--surface); border-radius: 14px; border: 1px solid var(--line); border-left: 5px solid var(--pc); overflow: hidden; }
  .look-b .ghead { display: flex; align-items: center; gap: 10px; padding: 12px 16px 10px; flex-wrap: wrap; }
  .look-b .ghead .chip { display: none; }
  .look-b .ghead b { font-size: 16px; font-weight: 650; }
  .look-b .ghead .path { color: var(--muted); font-size: 12.5px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0; flex: 1 1 200px; }
  .look-b .ghead .n { display: none; }
  .look-b .ghead + .rows { border-top: 1px solid var(--line-2); }
  .look-b .pport { justify-self: start; padding: 6px 10px; border-radius: 10px; font-size: 16px;
    background: color-mix(in srgb, var(--pc) 16%, var(--surface)); border: 1px solid color-mix(in srgb, var(--pc) 35%, var(--surface)); }
  .look-b { --portw: 92px; }
  .look-b .panel { background: var(--surface); border: 1px solid var(--line); border-radius: 14px; padding: 16px; }

  /* ================= C: sidebar app ================= */
  body.look-c {
    --bg: #f5f5f7; --side: #e9e9ec; --surface: #ffffff; --line: #e1e1e4; --line-2: #ededf0; --hover: #f6f6f8;
    --text: #1d1d1f; --text-2: #3a3a3e; --muted: #6e6e73; --accent: #0a64d6; --sel: #0a64d6; --sel-ink: #ffffff;
  }
  \#(Page.dark("--bg: #1c1c1e; --side: #252528; --surface: #2c2c2f; --line: #3a3a3e; --line-2: #343437; --hover: #333337; --text: #f2f2f4; --text-2: #d0d0d5; --muted: #98989e; --accent: #4c8dff; --sel: #0a5bd3;", "body.look-c"))
  .look-c .app { display: grid; grid-template-columns: 250px minmax(0, 1fr); min-height: 100vh; }
  .look-c .side { background: var(--side); border-right: 1px solid var(--line); padding: 16px 10px; display: flex; flex-direction: column; gap: 2px; position: sticky; top: 0; height: 100vh; overflow: auto; }
  .look-c .brand { display: flex; align-items: center; gap: 8px; font-weight: 650; font-size: 15px; padding: 2px 8px 12px; }
  .look-c .brand svg { width: 20px; height: 20px; color: var(--accent); }
  .look-c .sideh { font-size: 11.5px; font-weight: 600; color: var(--muted); padding: 10px 8px 4px; }
  .look-c .item { display: flex; align-items: center; gap: 8px; padding: 6px 8px; border-radius: 7px; cursor: pointer; font-size: 13.5px; border: 0; background: none; width: 100%; text-align: left; }
  .look-c .item:hover { background: color-mix(in srgb, var(--text) 6%, transparent); }
  .look-c .item[aria-current="true"] { background: var(--sel); color: var(--sel-ink); }
  .look-c .item .t { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .look-c .item .n { font: 12px var(--f-mono); color: var(--muted); }
  .look-c .item[aria-current="true"] .n { color: inherit; opacity: .85; }
  .look-c .item .tag.shared { padding: 2px 5px; font-size: 10px; }
  .look-c .item .chip { width: 9px; height: 9px; border-radius: 50%; }
  .look-c .sidefoot { margin-top: auto; padding: 12px 8px 0; font-size: 12px; color: var(--muted); display: grid; gap: 6px; }
  .look-c .pane { padding: 22px 28px 60px; display: grid; gap: 14px; align-content: start; max-width: 980px; }
  .look-c .ptitle { display: flex; align-items: baseline; gap: 12px; flex-wrap: wrap; }
  .look-c .ptitle h1 { font-size: 22px; font-weight: 650; }
  .look-c .ptitle .path { color: var(--muted); font-size: 12.5px; flex: 1 1 200px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0; }
  .look-c .list { display: grid; gap: 16px; }
  .look-c .grp { display: grid; gap: 6px; }
  .look-c .ghead { display: flex; align-items: center; gap: 8px; font-size: 12px; font-weight: 600; color: var(--muted); padding: 0 4px; }
  .look-c .ghead .path, .look-c .ghead .n, .look-c .ghead button { display: none; }
  .look-c .rows { background: var(--surface); border-radius: 10px; border: 1px solid var(--line); overflow: hidden; }
  .look-c .panel { background: var(--surface); border-radius: 10px; border: 1px solid var(--line); padding: 14px; }
  .look-c .mobile-only { display: none; }

  @media (max-width: 720px) {
    .rmain { grid-template-columns: auto minmax(0, 1fr); }
    .racts { grid-column: 1 / -1; justify-content: flex-start; }
    .rextra { padding-left: 14px; }
    .details { grid-template-columns: 5.4em minmax(0, 1fr) auto; }
    .mac { grid-template-columns: 1fr; }
    .apps li { grid-template-columns: minmax(0, 6.5em) minmax(0, 1fr) 4.2em 6.4em; }
    .look-a .top-in, .look-a main, .look-b .top-in, .look-b main { padding-inline: 14px; }
    .look-a .status span, .look-b .status span { display: none; }
    .look-a .ghead .path { display: none; }
    .look-a .ghead .n { margin-left: auto; }
    .look-c .app { grid-template-columns: 1fr; }
    .look-c .side { position: static; height: auto; flex-direction: row; overflow-x: auto; padding: 10px; gap: 6px; border-right: 0; border-bottom: 1px solid var(--line); }
    .look-c .brand { padding: 0 8px 0 2px; }
    .look-c .sideh, .look-c .sidefoot { display: none; }
    .look-c .item { width: auto; flex: none; white-space: nowrap; }
    .look-c .item .t { overflow: visible; }
    .look-c .pane { padding: 16px 14px 60px; }
  }
  @media (prefers-reduced-motion: reduce) { .spin { animation: none; } }
</style>
</head>
<body>
<svg width="0" height="0" style="position:absolute" aria-hidden="true">
  <symbol id="logo" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
    <path d="M12 3v6M6 9h12l2 6H4z"/><path d="M2 18c2-1.6 3.6-1.6 5.6 0s3.6 1.6 5.6 0 3.6-1.6 5.6 0"/>
  </symbol>
</svg>
<div class="app">
  <header class="top" id="top"></header>
  <nav class="side" id="side" hidden></nav>
  <main class="pane" id="pane">
    <div class="ptitle" id="ptitle" hidden></div>
    <div id="banners" style="display:grid;gap:8px"></div>
    <div class="toolbar">
      <input class="search" id="q" type="search" placeholder="Filter by port, project or PID" autocomplete="off" spellcheck="false" aria-label="Filter ports">
      <div class="seg" role="group" aria-label="Group ports">
        <button type="button" data-group="project" aria-pressed="true">Project</button>
        <button type="button" data-group="category" aria-pressed="false">Category</button>
        <button type="button" data-group="flat" aria-pressed="false">Flat</button>
      </div>
      <span class="range" title="Ports outside this range are hidden.">Ports
        <input type="number" id="rmin" min="1" max="65535" aria-label="Lowest port shown"> –
        <input type="number" id="rmax" min="1" max="65535" aria-label="Highest port shown"></span>
      <label class="check"><input type="checkbox" id="only-servers"> Servers only</label>
      <label class="check"><input type="checkbox" id="show-system"> <span id="show-system-label">macOS services</span></label>
      <button type="button" class="pl" id="refresh" title="Scan again now">Refresh</button>
    </div>
    <div class="list" id="list"></div>
    <p class="foot" id="foot"></p>
    <section class="panel mac" id="mac" aria-label="This Mac"></section>
  </main>
</div>
<div class="toast" id="toast" role="status" hidden></div>

<script>
'use strict';
const $ = (id) => document.getElementById(id);
const LOOK = ['a', 'b', 'c'].includes(new URLSearchParams(location.search).get('look')) ? new URLSearchParams(location.search).get('look') : 'a';
document.body.className = 'look-' + LOOK;
function pollMs() { const s = state ? state.settings.interval : 15; return s > 0 ? s * 1000 : 0; }
function cadence() { const s = state ? state.settings.interval : 15; return s === 0 ? 'manual' : s === 60 ? 'every minute' : `every ${s} s`; }
let state = null, timer = null, group = 'project', query = '', sel = 'all';
const phase = new Map(), sharing = new Map(), opened = new Set(), qrShown = new Set(), qrCache = new Map(), appPhase = new Map();
const sig = {};

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
  $(id).replaceChildren(...[build()].flat(Infinity).filter((k) => k != null && k !== false));
}
function logo() { const s = document.createElementNS('http://www.w3.org/2000/svg', 'svg'); const u = document.createElementNS('http://www.w3.org/2000/svg', 'use'); u.setAttribute('href', '#logo'); s.append(u); s.setAttribute('aria-hidden', 'true'); return s; }
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
function plural(n, one, many) { return n === 1 ? `1 ${one}` : `${n} ${many}`; }
function safeUrl(u) { return /^http:\/\/(localhost|127\.0\.0\.1|\[[0-9a-f:]+\]|[0-9.]+):\d+$/i.test(u) ? u : '#'; }
function safePublic(u) { return /^https:\/\/[a-z0-9-]+\.(trycloudflare\.com|ngrok(-free)?\.(app|dev|io))\/?$/i.test(u) ? u : '#'; }

// ---------- API (session cookie; POSTs add X-Harbor) ----------
async function api(path, body) {
  const opts = { credentials: 'same-origin', cache: 'no-store', headers: {} };
  if (body) { opts.method = 'POST'; opts.headers['Content-Type'] = 'application/json'; opts.headers['X-Harbor'] = '1'; opts.body = JSON.stringify(body); }
  const r = await fetch(path, opts);
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(data.error || ('HTTP ' + r.status));
  return data;
}
async function act(op, pid, extra) {
  try { return await api('/api/action', { op, pid, ...(extra || {}) }); } catch (e) { toast(e.message); return null; }
}
let offline = null;
async function poll() {
  clearTimeout(timer); timer = null;
  if (document.visibilityState !== 'visible') return;
  try {
    const next = await api('/api/state');
    if (next.quit) { offline = '__APP__ was quit. Type harbor.localhost in the address bar to start it again.'; renderBanners(); return; }
    state = next; offline = null; render();
  } catch (e) {
    offline = e.message === 'session'
      ? "This tab isn't signed in to __APP__. Type harbor.localhost in the address bar, or open __APP__ from the menu bar."
      : "__APP__ isn't answering. Open it from the menu bar or Applications, then reload this page.";
    renderBanners();
    if (e.message === 'session') return;
  }
  if (document.visibilityState === 'visible' && pollMs() > 0) timer = setTimeout(poll, pollMs());
}
window.addEventListener('focus', () => poll());
document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') poll(); else { clearTimeout(timer); timer = null; } });
let toastTimer = null;
function toast(text) { const t = $('toast'); t.textContent = text; t.hidden = false; clearTimeout(toastTimer); toastTimer = setTimeout(() => { t.hidden = true; }, 4200); }

// ---------- model ----------
const CATEGORY_ORDER = ['dev', 'database', 'runtime', 'appHelper', 'other', 'system'];
function visible() { return state.ports.filter((p) => !p.hidden); }
function matches(p) {
  if (!query) return true;
  const q = query.toLowerCase();
  return String(p.port).startsWith(q) || String(p.pid) === q || [p.name, p.title, p.framework, p.project, p.command, p.app].some((v) => v && v.toLowerCase().includes(q));
}
function groupKey(p) { return p.projectPath ? 'p:' + p.projectPath : 'a:' + (p.app || p.name); }
function model(ports) {
  if (group === 'flat') return [{ key: 'flat', title: 'All ports', rows: [...ports].sort((a, b) => a.port - b.port), flat: true }];
  if (group === 'category') return CATEGORY_ORDER.map((c) => {
    const rows = ports.filter((p) => p.category === c).sort((a, b) => a.port - b.port);
    return rows.length ? { key: 'c:' + c, title: rows[0].categoryTitle, rows, category: true } : null;
  }).filter(Boolean);
  const map = new Map();
  for (const p of ports) {
    const k = groupKey(p);
    if (!map.has(k)) map.set(k, { key: k, rows: [], rank: p.isProject ? 0 : p.projectPath ? 1 : 2, title: p.project || p.app || p.name, path: p.projectPath, folder: p.projectPath ? p.folder : null, color: p.color });
    map.get(k).rows.push(p);
  }
  return [...map.values()].map((g) => ({ ...g, rows: g.rows.sort((a, b) => a.port - b.port) }))
    .sort((a, b) => a.rank - b.rank || a.title.localeCompare(b.title, undefined, { sensitivity: 'base' }) || a.rows[0].port - b.rows[0].port);
}

// ---------- render ----------
function render() {
  if (state.settings.grouping) group = state.settings.grouping;
  // Appearance is shared with the menu and the default page.
  const theme = ['light', 'dark'].includes(state.settings.appearance) ? state.settings.appearance : 'auto';
  if (document.documentElement.dataset.theme !== theme) document.documentElement.dataset.theme = theme;
  const all = visible();
  const groups = model(all.filter(matches));
  if (LOOK === 'c') renderSide(model(all));
  renderTop(all);
  renderControls();
  renderBanners();
  renderList(groups);
  renderMac();
}

function renderTop(all) {
  const title = all.length ? `__app__ • ${plural(all.length, 'port', 'ports')}` : '__app__';
  if (document.title !== title) document.title = title;
  const exposed = all.filter((p) => p.exposed).length, shared = all.filter((p) => p.tunnel && p.tunnel.state === 'ready').length;
  const status = `Updated ${Math.round(state.scannedAgo)} s ago · ${cadence()}`;
  if (LOOK === 'c') {
    swap('side-status', status + all.length, () => [el('span', { text: plural(all.length, 'port', 'ports') + ' listening' }), el('span', { text: status })]);
    return;
  }
  const summary = [plural(all.length, 'server', 'servers') + ' listening', exposed ? `${exposed} reachable from your network` : null, shared ? `${shared} shared to the internet` : null].filter(Boolean).join(' · ');
  swap('top', [all.length, status, summary].join('|'), () => {
    const inner = el('div', { class: 'top-in' });
    const brand = el('div', { class: 'brand' }, logo(), '__app__', el('span', { class: 'count', text: LOOK === 'a' ? String(all.length) + ' ports' : plural(all.length, 'port', 'ports') }),
      el('span', { class: 'status' }, el('i', { class: 'dot' }), el('span', { text: status })));
    brand.style.width = '100%';
    inner.append(brand);
    if (LOOK === 'b') inner.append(el('p', { class: 'summary', text: summary }));
    const out = [inner];
    if (LOOK === 'b') {
      const w = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
      w.setAttribute('class', 'wave'); w.setAttribute('viewBox', '0 0 1200 14'); w.setAttribute('preserveAspectRatio', 'none');
      const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
      path.setAttribute('d', 'M0 7 C 100 0, 200 14, 300 7 S 500 0, 600 7 S 800 14, 900 7 S 1100 0, 1200 7');
      path.setAttribute('fill', 'none'); path.setAttribute('stroke', 'currentColor'); path.setAttribute('stroke-width', '1.5');
      w.append(path); out.push(w);
    }
    return out;
  });
}

function renderControls() {
  const st = state.settings;
  $('show-system').checked = st.showSystem;
  $('only-servers').checked = st.onlyServers;
  const sys = state.ports.filter((p) => p.system).length;
  $('show-system-label').textContent = sys ? `macOS services (${sys})` : 'macOS services';
  for (const [id, v] of [['rmin', st.minPort], ['rmax', st.maxPort]]) if (document.activeElement !== $(id)) $(id).value = v;
  for (const b of document.querySelectorAll('.seg button')) b.setAttribute('aria-pressed', String(b.dataset.group === group));
  const hidden = state.ports.filter((p) => p.hidden).length;
  $('foot').textContent = hidden ? `${plural(hidden, 'port is', 'ports are')} hidden by the range ${st.minPort}–${st.maxPort}${st.showSystem ? '' : ', macOS services'}${st.onlyServers ? ', servers only' : ''}.` : '';
}

function renderBanners() {
  const items = [];
  if (offline) items.push(['offline', offline, null]);
  if (state) {
    const z = state.zombies, p = z.alarm && z.parents[0];
    if (p) items.push(['alarm', `${p.name} is holding ${p.count.toLocaleString()} stuck processes. Past about ${z.perUser.toLocaleString()}, this Mac can't open anything new.`, p.canQuit ? p : null]);
    for (const n of state.notices.slice(-2)) items.push(['notice', n.text, n]);
  }
  swap('banners', JSON.stringify(items.map(([k, t, x]) => [k, t, x && (x.pid || x.id), x && appPhase.get(x.pid)])), () => items.map(([kind, text, extra]) =>
    el('div', { class: 'banner ' + kind }, el('p', { text }),
      kind === 'alarm' && extra ? quitControl(extra.pid, extra.name) : null,
      kind === 'notice' ? el('button', { class: 'pl', text: 'dismiss', onclick: async () => { await act('dismiss-notice', 0, { id: extra.id }); poll(); } }) : null)));
}

function renderSide(groups) {
  $('side').hidden = false;
  $('top').hidden = true;
  if (sel !== 'all' && sel !== 'mac' && !groups.some((g) => g.key === sel)) sel = 'all';
  const allCount = groups.reduce((n, g) => n + g.rows.length, 0);
  const shared = (rows) => rows.some((p) => p.tunnel && p.tunnel.state === 'ready');
  const item = (key, label, count, extra) => el('button', { class: 'item', 'aria-current': String(sel === key), onclick: () => { sel = key; render(); } },
    extra && extra.color ? el('i', { class: 'chip', style: { background: extra.color } }) : null,
    el('span', { class: 't', text: label }),
    extra && extra.shared ? el('span', { class: 'tag shared', text: 'shared' }) : null,
    count != null ? el('span', { class: 'n', text: String(count) }) : null);
  const lvl = { good: '#22a06b', warn: '#d9822b', bad: '#c5221f' }[state.verdict.level];
  swap('side', JSON.stringify([sel, group, groups.map((g) => [g.key, g.title, g.rows.length, shared(g.rows), g.color]), lvl]), () => [
    el('div', { class: 'brand' }, logo(), '__app__'),
    item('all', 'All ports', allCount),
    group === 'flat' ? null : el('p', { class: 'sideh', text: group === 'project' ? 'Projects' : 'Categories' }),
    group === 'flat' ? null : groups.map((g) => item(g.key, g.title, g.rows.length, { color: g.color, shared: shared(g.rows) })),
    el('p', { class: 'sideh', text: 'This Mac' }),
    el('button', { class: 'item', 'aria-current': String(sel === 'mac'), onclick: () => { sel = 'mac'; render(); } },
      el('i', { class: 'chip', style: { background: lvl } }), el('span', { class: 't', text: 'Memory and apps' })),
    el('div', { class: 'sidefoot', id: 'side-status' }),
  ]);
  sig['side-status'] = null;
}

function renderList(groups) {
  let shown = groups;
  if (LOOK === 'c') {
    $('ptitle').hidden = false;
    const g = groups.find((x) => x.key === sel);
    if (sel === 'mac') {
      swap('ptitle', 'mac', () => [el('h1', { text: 'This Mac' }), el('span', { class: 'path', text: 'Memory, and the apps holding most of it.' })]);
      $('mac').hidden = false; $('list').hidden = true; document.querySelector('.toolbar').hidden = true; $('foot').hidden = true;
      return;
    }
    $('mac').hidden = true; $('list').hidden = false; document.querySelector('.toolbar').hidden = false; $('foot').hidden = false;
    if (g) shown = [g];
    swap('ptitle', JSON.stringify([sel, g && g.title, g && g.path]), () => [
      el('h1', { text: g ? g.title : 'All ports' }),
      el('span', { class: 'path', text: g ? (g.path || (g.category ? 'Category' : 'App or service')) : 'Every server listening on this Mac' }),
      g && g.folder ? el('button', { class: 'pl', text: 'reveal', onclick: () => act('reveal', g.rows[0].pid) }) : null]);
  }
  const shape = shown.map((g) => [g.key, g.title, g.color, g.rows.map((p) => [p.id, p.title, p.name, p.framework, p.address, p.exposed, uptime(p.uptime), bytes(p.memory), p.workers, p.busy, p.system,
    p.tunnel, phase.get(p.id), sharing.get(p.id), opened.has(p.id), qrShown.has(p.port), p.command, p.folder, p.hint])]);
  swap('list', LOOK + group + JSON.stringify(shape), () => {
    if (!shown.length || !shown.some((g) => g.rows.length)) {
      return el('div', { class: 'empty' }, el('b', { text: query ? 'No matches' : 'No services listening' }),
        query ? 'Try a port number, a project name or a PID.' : "Start a dev server and it'll show up here within a few seconds.");
    }
    return shown.map((g) => {
      const head = g.flat && LOOK !== 'c' ? null : el('div', { class: 'ghead' },
        g.color ? el('i', { class: 'chip', style: { background: g.color } }) : null,
        el('b', { text: g.title }),
        g.path ? el('span', { class: 'path', text: g.path }) : el('span', { class: 'path', text: g.category ? '' : g.flat ? '' : 'App or service' }),
        el('span', { class: 'n', text: plural(g.rows.length, 'port', 'ports') }),
        g.folder ? el('button', { class: 'pl', text: 'reveal', onclick: () => act('reveal', g.rows[0].pid) }) : null);
      const projectInRow = g.flat || g.category || (LOOK === 'c' && sel === 'all' && group !== 'project');
      return el('section', { class: 'grp', style: { '--pc': g.color || 'var(--accent)' } }, head,
        el('ul', { class: 'rows' }, g.rows.map((p) => row(p, projectInRow))));
    });
  });
}

function pill(text, cls, onclick, title) {
  return el('button', { class: 'pl ' + (cls || ''), text, title, onclick: (e) => { e.stopPropagation(); onclick(); } });
}

function row(p, projectInRow) {
  const ph = phase.get(p.id), sh = sharing.get(p.id);
  const live = p.tunnel && p.tunnel.state === 'ready' ? p.tunnel : null;
  const title = projectInRow ? (p.project || p.app || p.name) : p.name;
  const facts = [projectInRow && title !== p.name ? p.name : null, 'pid ' + p.pid + (p.workers ? ` +${p.workers}` : ''), p.uptime != null ? 'up ' + uptime(p.uptime) : null, p.memory != null ? bytes(p.memory) : null].filter(Boolean).join(' · ');
  let acts;
  if ((ph && ph.kind === 'working') || p.busy) acts = el('span', { class: 'busy' }, el('i', { class: 'spin' }), 'stopping');
  else if (ph && ph.kind === 'confirm') acts = [pill('confirm?', 'confirm', () => runStop(p, 'stop')), pill('cancel', '', () => setPhase(p.id, null))];
  else if (ph && ph.kind === 'force') acts = [pill('force kill', 'force', () => runStop(p, 'force')), pill('cancel', '', () => setPhase(p.id, null))];
  else if (ph && ph.kind === 'admin') acts = [pill('admin password…', 'admin', () => runStop(p, 'admin')), pill('cancel', '', () => setPhase(p.id, null))];
  else if (sh && sh.kind === 'confirm') acts = [pill('share', 'go', () => startShare(p)), pill('cancel', '', () => setShare(p.id, null))];
  else acts = [
    el('a', { class: 'pl open', href: safeUrl(p.url), target: '_blank', rel: 'noopener noreferrer', text: 'open', title: 'Open ' + p.url, onclick: (e) => e.stopPropagation() }),
    pill('copy', '', () => copyText(p.url), 'Copy ' + p.url),
    p.system ? null : (p.tunnel && p.tunnel.state === 'starting' ? el('span', { class: 'busy' }, el('i', { class: 'spin' }), 'sharing')
      : p.tunnel ? pill('unshare', 'kill', () => stopShare(p), 'Stop sharing :' + p.port) : pill('share', 'share', () => askShare(p), 'Get a public link for :' + p.port)),
    p.system ? null : pill('kill', 'kill', () => armKill(p), 'Kill PID ' + p.pid),
  ];
  const extra = [];
  if (ph && ph.text) extra.push(el('p', { class: 'note' + (ph.kind === 'msg' ? ' info' : ''), text: ph.text }));
  if (sh && sh.kind === 'confirm') extra.push(el('p', { class: 'note share', text: sh.text }));
  if (sh && sh.kind === 'hint') extra.push(el('p', { class: 'note info' }, sh.text + ' ', el('code', { text: sh.command }), ' ', pill('copy command', '', () => copyText(sh.command))));
  if (p.tunnel && p.tunnel.state === 'starting') extra.push(el('p', { class: 'note info', text: `Opening a public link with ${p.tunnel.provider}…` }));
  if (live) {
    extra.push(el('div', { class: 'tunnel' }, 'Public link', el('a', { href: safePublic(live.url), target: '_blank', rel: 'noopener noreferrer', text: live.url, onclick: (e) => e.stopPropagation() }),
      pill('copy', '', () => copyText(live.url)), pill(qrShown.has(p.port) ? 'hide qr' : 'qr', '', () => { if (qrShown.has(p.port)) qrShown.delete(p.port); else qrShown.add(p.port); render(); })));
    if (qrShown.has(p.port)) extra.push(qrBox(p.port));
  }
  if (opened.has(p.id)) {
    const items = [];
    const add = (label, value, action) => items.push(el('dt', { text: label }), el('dd', { text: value }), action || el('span'));
    if (p.folder) add('Folder', p.folder, pill('reveal', '', () => act('reveal', p.pid)));
    if (p.command) add('Command', p.command);
    add('Address', p.address);
    add('URL', p.url, pill('copy', '', () => copyText(p.url)));
    if (p.hint) add('Note', p.hint);
    extra.push(el('dl', { class: 'details' }, items));
  }
  const toggle = () => { if (opened.has(p.id)) opened.delete(p.id); else opened.add(p.id); render(); };
  return el('li', { class: opened.has(p.id) ? 'open' : '', style: { '--pc': p.color } },
    el('div', { class: 'rmain', role: 'button', tabindex: '0', 'aria-expanded': String(opened.has(p.id)), onclick: toggle,
      onkeydown: (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggle(); } } },
      el('span', { class: 'pport', text: ':' + p.port }),
      el('div', { class: 'rtext' },
        el('div', { class: 'rtitle' }, el('span', { class: 't', text: title }),
          p.framework && p.framework !== title ? el('span', { class: 'tag', text: p.framework }) : null,
          p.macos ? el('span', { class: 'tag macos', text: 'macOS', title: 'Part of macOS' }) : null,
          p.exposed ? el('span', { class: 'tag warn', text: p.address, title: 'Other devices on your network can reach this port.' }) : null,
          live ? el('span', { class: 'tag shared', text: 'shared', title: 'Public link: ' + live.url }) : null),
        el('div', { class: 'rsub' }, projectInRow ? el('i', { class: 'chip', style: { background: p.color } }) : null, facts)),
      el('div', { class: 'racts' }, acts)),
    extra.length ? el('div', { class: 'rextra' }, extra) : null);
}

function qrBox(port) {
  const box = el('div', { class: 'qr', title: 'Scan with your phone camera' });
  const draw = (rows) => {
    const scale = 4, size = rows.length;
    const c = el('canvas', { width: size * scale, height: size * scale, 'aria-label': 'QR code of the public link' });
    const g = c.getContext('2d');
    g.fillStyle = '#fff'; g.fillRect(0, 0, c.width, c.height); g.fillStyle = '#000';
    rows.forEach((r, y) => { for (let x = 0; x < r.length; x++) if (r[x] === '1') g.fillRect(x * scale, y * scale, scale, scale); });
    box.replaceChildren(c);
  };
  if (qrCache.has(port)) draw(qrCache.get(port));
  else api('/api/qr?port=' + port).then((d) => { qrCache.set(port, d.rows); draw(d.rows); }).catch((e) => toast(e.message));
  return box;
}

// ---------- kill and share (same flows as the menu) ----------
function setPhase(id, v) { if (v) phase.set(id, v); else phase.delete(id); render(); }
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
  if (!r) return setPhase(p.id, null);
  if (r.result === 'still_running') setPhase(p.id, { kind: 'force', text: r.message });
  else if (r.result === 'not_permitted') setPhase(p.id, { kind: 'admin', text: r.message + ' macOS asks for the password in its own window; __APP__ never sees it.' });
  else if (r.result === 'system' || r.result === 'failed') setPhase(p.id, { kind: 'msg', text: r.message });
  else { setPhase(p.id, null); if (r.result !== 'cancelled') toast(r.message); }
  poll();
}
function setShare(id, v) { if (v) sharing.set(id, v); else sharing.delete(id); render(); }
function askShare(p) {
  if (!state.share.available) return setShare(p.id, { kind: 'hint', text: state.share.hint, command: state.share.command });
  const entry = { kind: 'confirm', text: `Anyone with the link can open ${p.project || p.app || p.name} on port ${p.port} until you stop sharing.` };
  setShare(p.id, entry);
  setTimeout(() => { if (sharing.get(p.id) === entry) setShare(p.id, null); }, 8000);
}
async function startShare(p) {
  setShare(p.id, null);
  const r = await act('share', p.pid, { port: p.port });
  if (r && r.result === 'unavailable') setShare(p.id, { kind: 'hint', text: r.message, command: state.share.command });
  poll();
}
async function stopShare(p) {
  const r = await act('unshare', p.pid, { port: p.port });
  if (r) toast(r.message);
  qrShown.delete(p.port); qrCache.delete(p.port);
  poll();
}
async function copyText(text) {
  try { await navigator.clipboard.writeText(text); toast('Copied ' + text); } catch (e) { toast('Copy failed; select the text instead.'); }
}

// ---------- This Mac ----------
function quitControl(pid, name) {
  const ph = appPhase.get(pid);
  if (ph === 'working') return el('span', { class: 'busy' }, el('i', { class: 'spin' }), 'quitting');
  if (ph === 'confirm') return el('span', { class: 'racts' }, pill('confirm?', 'confirm', () => quitApp(pid)), pill('cancel', '', () => { appPhase.delete(pid); render(); }));
  return pill('quit', 'kill', () => { appPhase.set(pid, 'confirm'); render(); setTimeout(() => { if (appPhase.get(pid) === 'confirm') { appPhase.delete(pid); render(); } }, 6000); }, 'Quit ' + name);
}
async function quitApp(pid) {
  appPhase.set(pid, 'working'); render();
  const r = await act('quit', pid);
  appPhase.delete(pid);
  if (r && r.result !== 'cancelled') toast(r.message);
  poll();
}
function renderMac() {
  const m = state.memory, v = state.verdict, apps = state.apps.slice(0, 6);
  const top = Math.max(1, ...apps.map((a) => a.memory));
  swap('mac', JSON.stringify([v.headline, bytes(m.used), bytes(m.swapUsed), m.pressure, state.loginItem, apps.map((a) => [a.id, bytes(a.memory), a.canQuit, appPhase.get(a.pid)])]), () => {
    const parts = [['Apps', m.app, '#4f8cf7'], ['Wired', m.wired, '#cf9214'], ['Compressed', m.compressed, '#9a84f4'], ['Cached', m.cached, '#16a6c2'], ['Free', m.free, 'var(--line)']];
    const login = el('label', { class: 'check' }, el('input', { type: 'checkbox', checked: !!state.loginItem, onchange: async (e) => { const r = await act('login-item', 0, { enabled: e.target.checked }); if (r) toast(r.message); poll(); } }), 'Open __APP__ at login');
    return [
      el('h2', {}, el('span', { text: 'This Mac' }), login),
      el('div', { class: 'mem' },
        el('p', { text: `${v.headline} ${bytes(m.used)} of ${bytes(m.physical)} in use, ${bytes(m.swapUsed)} of swap, pressure ${m.pressure}.` }),
        el('div', { class: 'ram' }, parts.map(([n, val, c]) => el('i', { title: `${n}: ${bytes(val)}`, style: { width: (val / m.physical * 100).toFixed(2) + '%', background: c } }))),
        el('div', { class: 'keys' }, parts.map(([n, val, c]) => el('span', {}, el('i', { class: 'chip', style: { background: c } }), n, el('b', { text: bytes(val) }))))),
      el('ul', { class: 'apps' }, apps.map((a) => el('li', {},
        el('span', { class: 'nm', text: a.name, title: a.folder ? `${a.name} · ${a.folder}` : a.name }),
        el('span', { class: 'track' }, el('i', { class: 'fill', style: { width: (a.memory / top * 100).toFixed(1) + '%' } })),
        el('span', { class: 'val', text: bytes(a.memory) }),
        a.canQuit ? quitControl(a.pid, a.name) : el('span')))),
    ];
  });
}

// ---------- controls ----------
async function saveSettings(change) { await act('settings', 0, change); poll(); }
for (const b of document.querySelectorAll('.seg button')) b.addEventListener('click', () => { group = b.dataset.group; if (state) { state.settings.grouping = group; render(); } saveSettings({ grouping: group }); });
$('show-system').addEventListener('change', (e) => saveSettings({ showSystem: e.target.checked }));
$('only-servers').addEventListener('change', (e) => saveSettings({ onlyServers: e.target.checked }));
for (const id of ['rmin', 'rmax']) $(id).addEventListener('change', () => {
  const lo = parseInt($('rmin').value, 10), hi = parseInt($('rmax').value, 10);
  if (lo >= 1 && hi >= 1) saveSettings({ minPort: lo, maxPort: hi });
});
$('q').addEventListener('input', (e) => { query = e.target.value.trim(); if (state) render(); });
$('refresh').addEventListener('click', () => poll());
poll();
</script>
</body>
</html>
"""#
}
