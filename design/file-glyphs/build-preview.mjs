// Rebuilds preview.html from the ic_file_*.svg files beside this script.
// The SVG files are the source of truth; run `node build-preview.mjs` after
// editing one. The page is self-contained (every glyph is inlined).
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));

// name, extensions it covers, sample file name for the mock card.
const GLYPHS = [
  ['pdf', 'pdf', 'Quarterly report.pdf'],
  ['doc', 'doc docx odt rtf pages', 'Meeting notes.docx'],
  ['sheet', 'xls xlsx ods numbers', 'Budget 2026.xlsx'],
  ['slides', 'ppt pptx odp key', 'Kickoff deck.pptx'],
  ['txt', 'txt md log', 'todo.txt'],
  ['data', 'csv json xml yaml', 'contacts export.json'],
  ['code', 'js ts py kt swift c cpp java cs sh html css', 'SyncEngine.kt'],
  ['archive', 'zip rar 7z tar gz', 'Photos backup.zip'],
  ['audio', 'mp3 m4a flac wav aac ogg m3u', 'Favorite (1).m3u'],
  ['video', 'mp4 mov mkv avi webm', 'Holiday clip.mp4'],
  ['package', 'apk hap app exe msi dmg', 'ClipLink-2.1.2.apk'],
  ['ebook', 'epub mobi azw3', 'Field guide.epub'],
  ['font', 'ttf otf woff', 'Inter-Medium.ttf'],
  ['disc', 'iso img', 'installer.iso'],
  ['generic', 'anything else (existing ic_chip_file)', 'backup.bin'],
];

// THEMES in mobile/harmonyos/.../pages/Index.ets, with the light and dark
// shades from resources/{base,dark}/element/color.json.
const THEMES = [
  ['navy', '#5468D4', '#5468D4'],
  ['teal', '#1E8C84', '#4DB6AC'],
  ['green', '#3D8F5A', '#66BB80'],
  ['orange', '#D9692F', '#F0935E'],
  ['rose', '#C24D7C', '#E07BA3'],
  ['violet', '#7B55C7', '#A084E0'],
];

const inner = (name) =>
  readFileSync(join(here, `ic_file_${name}.svg`), 'utf8')
    .replace(/<!--[\s\S]*?-->/g, '')
    .replace(/^[\s\S]*?<svg[^>]*>/, '')
    .replace(/<\/svg>\s*$/, '')
    .replace(/\s*\n\s*/g, '')
    .trim();

const symbols = GLYPHS.map(([n]) => `<symbol id="g-${n}" viewBox="0 0 24 24">${inner(n)}</symbol>`).join('\n');

const tile = (name, size, style = '') =>
  `<span class="t" style="--s:${size}px;${style}"><svg class="g" viewBox="0 0 24 24" aria-hidden="true"><use href="#g-${name}"/></svg></span>`;

const ext = (file) => file.slice(file.lastIndexOf('.') + 1).toUpperCase();

const catalogue = GLYPHS.map(([n, exts]) => `
      <div class="item">
        <div class="pair">${tile(n, 36)}${tile(n, 18)}</div>
        <div class="name">${n}</div>
        <div class="exts">${exts}</div>
      </div>`).join('');

const themeRows = (shade) => THEMES.map(([key, light, dark]) => {
  const c = shade === 'dark' ? dark : light;
  return `
        <div class="trow">
          <div class="tlabel"><b>${key}</b> <span>${c}</span></div>
          <div class="tiles">${GLYPHS.map(([n]) => tile(n, 36, `--accent:${c}`)).join('')}</div>
          <div class="tiles small">${GLYPHS.map(([n]) => tile(n, 18, `--accent:${c}`)).join('')}</div>
        </div>`;
}).join('');

const cards = GLYPHS.map(([n, , file]) => `
        <div class="card">
          ${tile(n, 36)}
          <div class="fname">${file}</div>
          <div class="sub">${tile(n, 18)}<span class="meta">17:42 · Laptop</span><span class="ext">${ext(file)}</span></div>
        </div>`).join('');

const zoom = (size) => GLYPHS.map(([n]) => `<figure>${tile(n, size)}<figcaption>${n}</figcaption></figure>`).join('');

const swatches = THEMES.map(([key, light, dark], i) =>
  `<button type="button" class="sw" data-l="${light}" data-d="${dark}" aria-pressed="${i === 0}" title="${key}"><i style="background:${light}"></i>${key}</button>`).join('');

const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ClipLink file glyphs</title>
<style>
  :root {
    color-scheme: light dark;
    --bg: #F6F7F8; --fg: #182431; --muted: #66727F; --rule: #DDE1E6; --panel: #FFFFFF;
    --accent-l: #5468D4; --accent-d: #5468D4; --accent: var(--accent-l);
  }
  @media (prefers-color-scheme: dark) {
    :root { --bg: #111214; --fg: #E8EAED; --muted: #9AA3AD; --rule: #2C2F34; --panel: #1A1C1F; --accent: var(--accent-d); }
  }
  * { box-sizing: border-box; }
  html { -webkit-text-size-adjust: 100%; }
  body {
    margin: 0; background: var(--bg); color: var(--fg);
    font: 14px/1.45 system-ui, -apple-system, "Segoe UI", "HarmonyOS Sans", Roboto, sans-serif;
  }
  main { max-width: 1120px; margin: 0 auto; padding: 24px 16px 64px; }
  h1 { font-size: 22px; font-weight: 600; margin: 0 0 4px; letter-spacing: -0.01em; }
  h2 { font-size: 15px; font-weight: 600; margin: 40px 0 4px; }
  p.lead, p.note { color: var(--muted); margin: 0 0 14px; max-width: 70ch; }
  code { font: 12px/1.4 ui-monospace, "Cascadia Mono", Consolas, monospace; }

  /* The tile: accent rounded square, radius size/3.2, glyph at 52%. */
  .t {
    --s: 36px;
    width: var(--s); height: var(--s); flex: none;
    border-radius: calc(var(--s) / 3.2);
    background: var(--accent);
    display: inline-grid; place-items: center;
  }
  .t svg { width: 52%; height: 52%; display: block; }
  .g { fill: none; stroke: #FFFFFF; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }

  .picker { display: flex; flex-wrap: wrap; gap: 6px; margin: 14px 0 0; }
  .sw {
    font: inherit; font-size: 12px; color: var(--fg); background: var(--panel);
    border: 1px solid var(--rule); border-radius: 999px; padding: 4px 10px 4px 6px;
    display: inline-flex; align-items: center; gap: 6px; cursor: pointer;
  }
  .sw i { width: 12px; height: 12px; border-radius: 50%; display: block; }
  .sw[aria-pressed="true"] { border-color: var(--fg); }

  .catalogue { display: grid; grid-template-columns: repeat(auto-fill, minmax(148px, 1fr)); gap: 8px; }
  .item { background: var(--panel); border: 1px solid var(--rule); border-radius: 12px; padding: 12px; min-width: 0; }
  .pair { display: flex; align-items: flex-end; gap: 10px; margin-bottom: 10px; }
  .name { font-weight: 600; }
  .exts { color: var(--muted); font-size: 12px; overflow-wrap: anywhere; }

  /* Fixed-colour stages: these stay light or dark whatever the page chrome does. */
  .stage { border-radius: 14px; padding: 14px 12px; margin-bottom: 10px; border: 1px solid var(--rule); }
  .stage.light { background: #F1F3F5; color: #182431; --accent: var(--accent-l); --s-muted: #6B7785; --s-card: #FFFFFF; }
  .stage.dark { background: #0E0F11; color: #E8EAED; --accent: var(--accent-d); --s-muted: #98A1AB; --s-card: #1E2023; }
  .stage > h3 { font-size: 12px; font-weight: 600; margin: 0 0 10px; color: var(--s-muted); text-transform: uppercase; letter-spacing: 0.06em; }

  .trow { display: grid; grid-template-columns: 96px 1fr; gap: 6px 10px; align-items: center; padding: 8px 0; }
  .trow + .trow { border-top: 1px solid color-mix(in srgb, currentColor 10%, transparent); }
  .tlabel { font-size: 12px; grid-row: span 2; align-self: start; padding-top: 9px; }
  .tlabel span { display: block; color: var(--s-muted); font-family: ui-monospace, Consolas, monospace; font-size: 11px; }
  .tiles { display: flex; flex-wrap: wrap; gap: 6px; min-width: 0; }
  @media (max-width: 520px) {
    .trow { grid-template-columns: 1fr; }
    .tlabel { grid-row: auto; padding-top: 0; }
    .tlabel span { display: inline; margin-left: 6px; }
  }

  /* Mock grid file card, real size. */
  .cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(148px, 1fr)); gap: 10px; }
  .card { background: var(--s-card); border-radius: 16px; padding: 12px; min-width: 0; display: flex; flex-direction: column; align-items: flex-start; }
  .fname { font-size: 14px; font-weight: 500; line-height: 19px; margin: 10px 0 8px; max-width: 100%; overflow-wrap: anywhere; }
  .sub { display: flex; align-items: center; gap: 6px; width: 100%; font-size: 11px; line-height: 18px; color: var(--s-muted); margin-top: auto; }
  .sub .meta { flex: 1; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .sub .ext { font-weight: 600; letter-spacing: 0.04em; }

  .zoom { display: flex; flex-wrap: wrap; gap: 12px; }
  figure { margin: 0; text-align: center; }
  figcaption { font-size: 11px; color: var(--muted); margin-top: 4px; }
</style>
</head>
<body>
<svg width="0" height="0" style="position:absolute" aria-hidden="true">
${symbols}
</svg>
<main>
  <h1>ClipLink file glyphs</h1>
  <p class="lead">Fifteen file-type glyphs in the type-chip style: 24&times;24, white 2&nbsp;px round strokes, drawn at 52% of an accent tile with a corner radius of size/3.2. Nothing here is in the apps yet.</p>
  <div class="picker" id="picker" aria-label="Accent for sections 1, 3 and 4">${swatches}</div>

  <h2>1. Glyphs at 36 px and 18 px</h2>
  <p class="note">Left tile is the grid card size, right tile is the subtitle-row size.</p>
  <div class="catalogue">${catalogue}
  </div>

  <h2>2. Every theme accent</h2>
  <p class="note">Each theme's light-mode shade on a light page and dark-mode shade on a dark page, at 36 px and 18 px.</p>
  <div class="stage light"><h3>Light mode shades</h3>${themeRows('light')}
  </div>
  <div class="stage dark"><h3>Dark mode shades</h3>${themeRows('dark')}
  </div>

  <h2>3. In a grid file card, real size</h2>
  <p class="note">36 px tile, 14 px medium file name, then the 18 px tile with time, device and extension.</p>
  <div class="stage light"><h3>Light</h3>
    <div class="cards">${cards}
    </div>
  </div>
  <div class="stage dark"><h3>Dark</h3>
    <div class="cards">${cards}
    </div>
  </div>

  <h2>4. Stroke check</h2>
  <p class="note">The 36 px tile at 2&times; and 4&times;.</p>
  <div class="zoom">${zoom(72)}</div>
  <div class="zoom" style="margin-top:20px">${zoom(144)}</div>
</main>
<script>
  // Accent picker for sections 1, 3 and 4 (section 2 always shows every theme).
  document.getElementById('picker').addEventListener('click', function (e) {
    var b = e.target.closest('.sw');
    if (!b) return;
    document.documentElement.style.setProperty('--accent-l', b.dataset.l);
    document.documentElement.style.setProperty('--accent-d', b.dataset.d);
    this.querySelectorAll('.sw').forEach(function (s) { s.setAttribute('aria-pressed', String(s === b)); });
  });
</script>
</body>
</html>
`;

writeFileSync(join(here, 'preview.html'), html);
console.log(`preview.html written (${(html.length / 1024).toFixed(1)} kB, ${GLYPHS.length} glyphs)`);
