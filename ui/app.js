'use strict';
// Catchlight desktop UI prototype. Plain web platform only (no framework, no build
// step, no platform-only APIs) so the same files run in WKWebView, WebView2 and
// WebKitGTK (D-318). Data is placeholder and in-page; nothing syncs.

// ---------- Iris: the six-blade shutter, paths from Catchlight-Ops/blade_paths.json ----------
const BLADES = ["M28.39 15.16C27.15 14.22 25.79 13.32 24.34 12.48C22.89 11.65 21.43 10.92 20.0 10.31C17.62 9.29 15.31 8.59 13.19 8.21C8.6 7.39 4.93 8.12 3.55 10.5C3.55 10.5 3.55 10.5 3.55 10.5C6.83 4.82 12.97 1.01 20.0 1.01C22.76 1.01 25.22 3.82 26.81 8.21C27.54 10.23 28.09 12.58 28.39 15.16Z", "M33.61 20.0C32.23 21.64 30.47 23.3 28.39 24.85C28.58 23.3 28.68 21.68 28.68 20.0C28.68 18.32 28.58 16.7 28.39 15.15C28.09 12.58 27.54 10.22 26.81 8.21C25.22 3.82 22.76 1.01 20.0 1.01C27.03 1.01 33.17 4.82 36.45 10.5C36.45 10.5 36.45 10.5 36.45 10.5C37.83 12.89 36.62 16.43 33.61 20.0Z", "M38.99 20.0C38.99 23.46 38.07 26.7 36.45 29.5C36.45 29.5 36.45 29.5 36.45 29.5C35.07 31.89 31.41 32.61 26.81 31.79C24.7 31.42 22.38 30.71 20.01 29.69C21.44 29.08 22.89 28.35 24.35 27.52C25.8 26.68 27.16 25.78 28.4 24.84C30.47 23.29 32.23 21.64 33.62 19.99C36.62 16.42 37.84 12.88 36.45 10.5C36.45 10.5 36.45 10.5 36.45 10.5C38.07 13.3 38.99 16.54 38.99 20.0Z", "M36.45 29.5C33.17 35.18 27.03 38.99 20.0 38.99C17.24 38.99 14.78 36.18 13.19 31.79C12.46 29.77 11.91 27.42 11.61 24.85C12.85 25.79 14.21 26.69 15.66 27.52C17.11 28.36 18.57 29.09 20.0 29.7C22.38 30.72 24.69 31.42 26.81 31.8C31.4 32.61 35.07 31.88 36.45 29.5C36.45 29.5 36.45 29.5 36.45 29.5Z", "M20.0 38.99C12.97 38.99 6.83 35.18 3.55 29.5C3.55 29.5 3.55 29.5 3.55 29.5C2.17 27.11 3.38 23.58 6.39 20.01C7.77 18.37 9.53 16.71 11.61 15.16C11.42 16.7 11.32 18.32 11.32 20.01C11.32 21.69 11.42 23.31 11.61 24.86C11.91 27.42 12.46 29.78 13.19 31.8C14.79 36.18 17.24 38.99 20.0 38.99Z", "M20.0 10.31C18.57 10.92 17.11 11.65 15.66 12.48C14.21 13.32 12.85 14.22 11.61 15.16C9.53 16.71 7.77 18.36 6.39 20.01C3.38 23.58 2.17 27.12 3.55 29.5C3.55 29.5 3.55 29.5 3.55 29.5C1.94 26.71 1.01 23.46 1.01 20.0C1.01 16.54 1.94 13.3 3.55 10.5C3.55 10.5 3.55 10.5 3.55 10.5C4.93 8.11 8.6 7.39 13.19 8.21C15.31 8.59 17.62 9.29 20.0 10.31Z"];
const SEG = ['important', 'task', 'image', 'note', 'voice', 'remind'];

function iris(active = [], obie = false) {
  const on = new Set(obie ? [...active, 'important'] : active);
  const edge = obie ? 'var(--iris-obie)' : 'var(--iris-ring)';
  let s = '<svg class="iris" viewBox="0.85 0.85 38.3 38.3" aria-hidden="true" style="stroke:none;overflow:visible">';
  BLADES.forEach((d, i) => { s += `<path d="${d}" fill="${on.has(SEG[i]) ? `var(--iris-${SEG[i]})` : 'var(--iris-off)'}"/>`; });
  BLADES.forEach(d => { s += `<path d="${d}" fill="url(#iris-sheen)"/>`; }); // metal sheen, lit from the top-left
  BLADES.forEach(d => { s += `<path d="${d}" fill="none" stroke="${edge}" stroke-width="0.7"/>`; });
  s += `<circle cx="20" cy="20" r="18.7" fill="none" stroke="${edge}" stroke-width="0.9"/>`;
  if (obie) s += '<circle cx="20" cy="20" r="21.76" fill="none" stroke="var(--iris-obie)" stroke-width="1.74"/>';
  // The rim catchlight: hot core and bloom at ten o'clock, dim bounce opposite
  // (TakeCircleView.glint). An Obie catches it on both rings. turnGlints() swings it.
  s += '<g class="glints">' + glint(0.976, 0.052, 0.235, 0.150) + (obie ? glint(1.109, 0.040, 0.180, 0.115) : '') + '</g>';
  return s + '</svg>';
}
function glint(unit, core, bloom, bounce) {
  const R = 19.15; // the shutter's outer radius in blade units: iOS's diameter / 2
  const d = unit * R * Math.SQRT1_2, near = 20 - d, far = 20 + d; // 225°: up and left of centre
  return `<circle cx="${far}" cy="${far}" r="${bounce * R}" fill="url(#glint-bounce)"/>`
    + `<circle cx="${near}" cy="${near}" r="${bloom * R}" fill="url(#glint-bloom)"/>`
    + `<circle cx="${near}" cy="${near}" r="${core * R}" fill="#FFFEF8"/>`;
}

// ---------- small helpers ----------
const $ = s => document.querySelector(s);
const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const store = {
  get(k, d) { try { const v = localStorage.getItem('cl.' + k); return v == null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { localStorage.setItem('cl.' + k, JSON.stringify(v)); } catch { /* storage unavailable: session only */ } },
};
const monthKey = iso => { const d = new Date(iso.length === 10 ? iso + 'T00:00' : iso); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`; };
const monthLabel = iso => new Date(iso.length === 10 ? iso + 'T00:00' : iso).toLocaleDateString('en-GB', { month: 'long', year: 'numeric' }).toUpperCase();
const debounce = (fn, ms) => { let t; return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); }; };
const ICON_CLOCK = '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></svg>';
const ICON_BELL = '<svg viewBox="0 0 24 24"><path d="M6 16V11a6 6 0 0 1 12 0v5l1.5 2h-15zM10 20.5h4"/></svg>';
const ICON_CHECKLIST = '<svg viewBox="0 0 24 24"><path d="M4 7l1.6 1.6L8.5 5.5M4 15l1.6 1.6 2.9-3.1M11.5 7.5h8.5M11.5 15.5h8.5"/></svg>';
const ICON_IMPORTANT = '<span class="bang">!</span>';
const ICON_XMARK = '<svg class="xmark" viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M9 9l6 6M15 9l-6 6"/></svg>';

// ---------- placeholder data (Takes live in takes.js) ----------
const LETTER_REGIONS = new Set(['US', 'CA', 'MX', 'PH', 'CL', 'CO', 'VE', 'PR', 'GT', 'CR', 'DO', 'PA', 'SV', 'NI', 'HN', 'BO']);
function regionPaper() {
  try { const r = new Intl.Locale(navigator.language).maximize().region; return LETTER_REGIONS.has(r) ? 'letter' : 'a4'; } catch { return 'a4'; }
}

let scripts = store.get('scripts', [
  { id: 's1', at: '2026-06-12', mode: 'a4', blocks: [
    '# Winter series',
    'Notes towards a set of twelve prints. *Cold light, long shadows, one subject, no colour.*',
    '## What it is',
    'A year of mornings on the same stretch of coast, shot only when the sun is under **ten degrees** above the horizon.',
    '- Twelve prints, one per month',
    '- Same tripod position, marked with a brass pin',
    '- Black and white only',
    '## Still to decide',
    '- [x] Paper stock',
    '- [ ] Frame size',
    '- [ ] Whether to show the contact sheets',
    '> The tool didn\'t catch it. Understanding it caught it.',
    'Reference: [the Whitby shoot](https://catchlight.app) and the notes in `prints/2026`.',
  ] },
  { id: 's2', at: '2026-07-03', mode: 'continuous', blocks: [
    '# Studio handbook',
    'Everything a second pair of hands needs on day one.',
    '## Opening up',
    '1. Lights on at the board, not the wall switches',
    '2. Dehumidifier to 45%',
    '3. Check the print queue',
    '---',
    '## Kit that never leaves',
    'The **grey card**, the ~~old~~ new light meter, and the spare batteries in the top drawer.',
  ] },
  { id: 's3', at: '2026-07-18', mode: regionPaper(), blocks: [
    '# Exhibition proposal',
    'Draft for the gallery, due end of August.',
    '```\nTitle: Winter series\nWorks: 12 silver gelatin prints\nSize: 40 x 50 cm framed\n```',
    'The pitch in one line: a year of the same view, and how much of it changes.',
  ] },
]);

const view = Object.assign({ preview: 'some', spacing: 'standard', sort: 'oldest' }, store.get('view', {}));
let current = store.get('current', 's1');
let query = '';
const save = () => { store.set('scripts', scripts); store.set('current', current); };

// ---------- the two Dailies-style timelines ----------
function timeline(container, items, cardHtml) {
  let html = '', month = '';
  for (const it of items) {
    const m = monthLabel(it.at);
    if (m !== month) { html += `<div class="month" data-month="${monthKey(it.at)}"><span class="month-label">${m}</span></div>`; month = m; }
    html += cardHtml(it);
  }
  container.innerHTML = html;
}

const plain = s => s.replace(/^```.*$/gm, '').replace(/^(#{1,3}|>|[-*] \[[ xX]\]|[-*]|\d+\.)\s+/gm, '')
  .replace(/\*\*|~~|`|\*/g, '').replace(/\[([^\]]+)\]\([^)]+\)/g, '$1').replace(/^-{3,}$/gm, '').replace(/\n{2,}/g, '\n').trim();
const titleOf = s => (s && plain(s.blocks[0] || '')) || (s ? 'Untitled Script' : '');

function renderScripts() {
  const tl = $('#scripts');
  tl.dataset.preview = view.preview; tl.dataset.spacing = view.spacing;
  let items = scripts.filter(s => !query || s.blocks.join('\n').toLowerCase().includes(query));
  items.sort((a, b) => view.sort === 'oldest' ? a.at.localeCompare(b.at) : b.at.localeCompare(a.at));
  timeline(tl, items, s => {
    const body = plain(s.blocks.join('\n')) || 'Untitled Script';
    const pages = s.mode === 'continuous' ? 'Continuous' : `${s.mode === 'a4' ? 'A4' : 'US Letter'}${s.pageCount ? ` · ${s.pageCount} page${s.pageCount > 1 ? 's' : ''}` : ''}`;
    return `<div class="card${s.id === current ? ' selected' : ''}" data-script="${s.id}"><span class="iris-wrap"><span class="iris-shadow"></span>${iris(['note'])}</span><div class="body">${esc(body)}</div><div class="pages">${pages}</div></div>`;
  });
}

// ---------- markdown: one parser, two faces (source while editing, rendered otherwise) ----------
// A table is one block: a header row, a separator row of dashes, then body rows.
const isTable = t => /^\|.*\|[ \t]*\n\|[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)*\|[ \t]*(\n|$)/.test(t);   // GFM: one dash is enough
// An escaped pipe (\|) belongs to its cell, as in GFM; the cell editor stores a typed | that way.
const PIPE = /(?<!\\)\|/g;
const cells = line => line.trim().replace(/^\|/, '').replace(/(?<!\\)\|$/, '').split(PIPE).map(c => c.trim());
function tableHtml(t) {
  const [head, sep, ...body] = t.split('\n');
  const align = cells(sep).map(c => c.startsWith(':') && c.endsWith(':') ? 'center' : c.endsWith(':') ? 'right' : '');
  const td = (tag, row) => cells(row).map((c, i) => `<${tag}${align[i] ? ` style="text-align:${align[i]}"` : ''}>${inline(c.replace(/\\\|/g, '|'), false)}</${tag}>`).join('');
  return `<table><thead><tr>${td('th', head)}</tr></thead><tbody>${body.filter(r => r.trim() && r.trim() !== '|').map(r => `<tr>${td('td', r)}</tr>`).join('')}</tbody></table>`;
}

function classify(t) {
  let m;
  if (/^```/.test(t)) return { type: 'code', pre: '' };
  if (isTable(t)) return { type: 'table', pre: '' };
  if ((m = t.match(/^(#{1,3}) /))) return { type: 'h' + m[1].length, pre: m[0] };
  if ((m = t.match(/^> /))) return { type: 'quote', pre: m[0] };
  if ((m = t.match(/^[-*] \[( |x|X)\] /))) return { type: 'check', pre: m[0], done: m[1] !== ' ' };
  if ((m = t.match(/^[-*] /))) return { type: 'li', pre: m[0] };
  if ((m = t.match(/^(\d+)\. /))) return { type: 'li ol', pre: m[0], n: m[1] };
  if (/^(-{3,}|\*{3,})$/.test(t)) return { type: 'hr', pre: '' };
  return { type: 'p', pre: '' };
}

function inline(src, source) {
  const keep = [];
  const hold = h => `\u0000${keep.push(h) - 1}\u0000`;
  const mk = s => source ? `<span class="mk">${s}</span>` : '';
  let h = esc(src);
  h = h.replace(/`([^`\n]+)`/g, (_, c) => hold(source ? `<span class="c">${mk('`')}${c}${mk('`')}</span>` : `<code>${c}</code>`));
  h = h.replace(/\[([^\]\n]+)\]\(([^)\s]+)\)/g, (_, label, url) => {
    if (source) return `${mk('[')}<span class="a">${label}</span>${mk(`](${url})`)}`;
    const safe = /^(https?:|mailto:)/i.test(url) ? ` href="${url}" target="_blank" rel="noopener"` : '';
    return `<a${safe}>${label}</a>`;
  });
  h = h.replace(/\*\*(?=\S)([^*\n]+?)\*\*/g, (_, x) => source ? `<span class="b">${mk('**')}${x}${mk('**')}</span>` : `<strong>${x}</strong>`);
  h = h.replace(/~~(?=\S)([^~\n]+?)~~/g, (_, x) => source ? `<span class="s">${mk('~~')}${x}${mk('~~')}</span>` : `<s>${x}</s>`);
  h = h.replace(/(^|[^*\w])\*(?=[^\s*])([^*\n]+?)\*(?!\*)/g, (_, p, x) => source ? `${p}<span class="i">${mk('*')}${x}${mk('*')}</span>` : `${p}<em>${x}</em>`);
  return h.replace(/\u0000(\d+)\u0000/g, (_, i) => keep[i]);
}

function paint(el, text, active) {
  const k = classify(text);
  el.className = `blk ${k.type}${active ? ' active' : ''}${text === '' ? ' empty' : ''}${k.done ? ' done' : ''}`;
  if (k.n) el.dataset.n = k.n + '.'; else delete el.dataset.n;
  const i = +el.dataset.i;
  if (i === 0 && text === '') { el.classList.add('placeholder'); el.dataset.ph = 'Title'; } else el.classList.remove('placeholder');
  if (active) {
    if (k.type === 'code') el.innerHTML = esc(text).replace(/^```.*$/gm, l => `<span class="mk">${l}</span>`);
    else if (k.type === 'table') { paintGrid(el, text); return; }
    else el.innerHTML = (k.pre ? `<span class="mk">${esc(k.pre)}</span>` : '') + inline(text.slice(k.pre.length), true);
    if (text.endsWith('\n')) el.innerHTML += '<br>';
    return;
  }
  const rest = text.slice(k.pre.length);
  if (k.type === 'code') el.textContent = text.replace(/^```.*\n?/, '').replace(/\n?```\s*$/, '');
  else if (k.type === 'hr') el.textContent = text;
  else if (k.type === 'table') el.innerHTML = tableHtml(text);
  else if (k.type === 'check') el.innerHTML = `<input type="checkbox"${k.done ? ' checked' : ''} aria-label="Done"><span class="txt">${inline(rest, false)}</span>`;
  else el.innerHTML = inline(rest, false);
}

// ---------- caret helpers (offsets are in source characters) ----------
function caretOffset(el) {
  const sel = getSelection();
  if (!sel.rangeCount || !el.contains(sel.focusNode)) return null;
  const r = document.createRange();
  r.selectNodeContents(el); r.setEnd(sel.focusNode, sel.focusOffset);
  return r.toString().length;
}
function setCaret(el, off) {
  const w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
  let n, left = off;
  while ((n = w.nextNode())) { if (left <= n.length) break; left -= n.length; }
  const r = document.createRange();
  if (n) r.setStart(n, Math.max(0, left)); else { r.selectNodeContents(el); r.collapse(false); }
  r.collapse(true);
  const sel = getSelection(); sel.removeAllRanges(); sel.addRange(r);
}
function caretLine(el) {
  const sel = getSelection();
  if (!sel.rangeCount) return { first: true, last: true };
  const rect = sel.getRangeAt(0).getClientRects()[0];
  if (!rect) return { first: true, last: true };
  const box = el.getBoundingClientRect(), lh = parseFloat(getComputedStyle(el).lineHeight) || 24;
  return { first: rect.top - box.top < lh * 0.9, last: box.bottom - rect.bottom < lh * 0.9 };
}

// ---------- the Script editor ----------
const doc = $('#doc');
let active = -1;
const script = () => scripts.find(s => s.id === current);

function renderDoc() {
  const s = script();
  active = -1;
  doc.innerHTML = '';
  if (!s) { applyMode(); return; } // clears page sheets left by the last Script
  if (!s.blocks.length) s.blocks.push('');
  s.blocks.forEach((t, i) => { const el = document.createElement('div'); el.dataset.i = i; doc.append(el); paint(el, t, false); });
  applyMode();
}

function activate(i, off) {
  const s = script();
  if (active >= 0 && active !== i) deactivate();
  const el = doc.children[i];
  if (!el) return;
  active = i;
  if (classify(s.blocks[i]).type === 'table') {
    paint(el, s.blocks[i], true);
    const { r, c, o } = cellAt(s.blocks[i], off == null ? s.blocks[i].length : off);
    focusCell(el, r, c, o);
    return;
  }
  try { el.contentEditable = 'plaintext-only'; } catch { el.contentEditable = 'true'; }
  paint(el, s.blocks[i], true);
  el.focus({ preventScroll: true });
  setCaret(el, off == null ? s.blocks[i].length : off);
  el.scrollIntoView({ block: 'nearest' });
}
function deactivate() {
  const el = doc.children[active];
  if (el) { el.removeAttribute('contenteditable'); paint(el, script().blocks[active], false); }
  active = -1;
}
function rebuild(focusI, off) { renderDoc(); activate(focusI, off); changed(); }

const changed = debounce(() => { save(); renderScripts(); $('#script-heading').textContent = titleOf(script()); paginate(); }, 250);

// ---------- undo across the whole Script ----------
// The browser's own undo cannot span blocks, and repainting a block as you type breaks it
// within one too, so the editor keeps its own: a snapshot of every block before each change.
// Typing coalesces into one step until a pause of a second; splitting, merging, ticking and
// starting a table are a step each. ⌘Z undoes, ⇧⌘Z (or ⌃Y) redoes, and so does the Edit menu.
const edits = { undo: [], redo: [], typing: 0, block: -1, id: null };
function snapshot() {
  return { blocks: [...script().blocks], active, off: active >= 0 ? blockOffset() : null };
}
function remember(kind) {
  const s = script();
  if (!s) return;
  if (edits.id !== s.id) Object.assign(edits, { undo: [], redo: [], typing: 0, id: s.id });
  const now = Date.now();
  // Typing coalesces only while it stays in the same block, with less than a second between keys.
  if (kind === 'type' && edits.block === active && now - edits.typing < 1000) { edits.typing = now; return; }
  edits.typing = kind === 'type' ? now : 0;
  edits.block = active;
  edits.undo.push(snapshot());
  if (edits.undo.length > 200) edits.undo.shift();
  edits.redo = [];
}
function step(from, to) {
  const s = script();
  if (!s || edits.id !== s.id || !from.length) return;
  to.push(snapshot());
  const snap = from.pop();
  s.blocks = [...snap.blocks];
  edits.typing = 0;
  if (snap.active >= 0) rebuild(Math.min(snap.active, s.blocks.length - 1), snap.off);
  else { renderDoc(); changed(); }
}
const undo = () => step(edits.undo, edits.redo);
const redo = () => step(edits.redo, edits.undo);
doc.addEventListener('beforeinput', e => {
  if (e.inputType === 'historyUndo') { e.preventDefault(); undo(); }
  else if (e.inputType === 'historyRedo') { e.preventDefault(); redo(); }
  // Typed characters and deletions coalesce; a paste, cut or drop is a step of its own.
  else if (active >= 0) remember(/^(insertText|insertReplacementText|deleteContent)/.test(e.inputType) ? 'type' : 'edit');
});

function onInput() {
  if (active < 0) return;
  if (classify(script().blocks[active]).type === 'table') { tableInput(); return; }
  const el = doc.children[active];
  const off = caretOffset(el);
  script().blocks[active] = el.textContent;
  // A pasted table: the grid takes over from the block's own editing.
  if (classify(el.textContent).type === 'table') { el.removeAttribute('contenteditable'); activate(active, off); changed(); return; }
  paint(el, el.textContent, true);
  if (off != null) setCaret(el, off);
  changed();
}
doc.addEventListener('input', e => { if (!e.isComposing) onInput(); });
// The input that ends a composition (an IME, dead keys) can still say isComposing, so the text
// it committed is read here too.
doc.addEventListener('compositionend', onInput);

doc.addEventListener('keydown', e => {
  if (active < 0 || e.isComposing) return;
  const s = script(), el = doc.children[active], text = s.blocks[active];
  const off = caretOffset(el) ?? text.length;
  const k = classify(text);
  const collapsed = getSelection().isCollapsed;

  if ((e.metaKey || e.ctrlKey) && !e.altKey && (e.key.toLowerCase() === 'z' || (e.ctrlKey && e.key.toLowerCase() === 'y'))) {
    e.preventDefault();
    if (e.shiftKey || e.key.toLowerCase() === 'y') redo(); else undo();
    return;
  }
  if (k.type === 'table') { tableKey(e, s, el, text); return; }   // the grid's own keys
  // A header row, "| a | b |", becomes a table on Enter: the separator and a first row follow.
  if (e.key === 'Enter' && k.type === 'p' && !text.includes('\n') && /^\|.*\|.*\|\s*$/.test(text) && off === text.length) {
    e.preventDefault();
    remember('edit');
    const n = cells(text).length;
    s.blocks[active] = tableText({ rows: [cells(text), Array(n).fill('')], sep: Array(n).fill('---') });
    el.removeAttribute('contenteditable');   // the grid's cells are the editors now
    activate(active, sourceAt(s.blocks[active], 1, 0, 0)); changed();
    return;
  }
  // Return is the line break: Shift+Enter does what Enter does (owner, 2026-10-02), except in a
  // code block, where a line is part of the block until its closing fence.
  if (e.key === 'Enter' && k.type === 'code' && !/\n```\s*$/.test(text)) {
    e.preventDefault();
    remember('edit');
    s.blocks[active] = text.slice(0, off) + '\n' + text.slice(off);
    paint(el, s.blocks[active], true); setCaret(el, off + 1); changed();
  } else if (e.key === 'Enter') {
    e.preventDefault();
    remember('edit');
    if (k.pre && text.length === k.pre.length && /li|check/.test(k.type)) { s.blocks[active] = ''; return rebuild(active, 0); }
    let next = '';
    if (k.type === 'check') next = '- [ ] ';
    else if (k.type === 'li') next = k.pre;
    else if (k.type === 'li ol') next = `${+k.n + 1}. `;
    s.blocks[active] = text.slice(0, off);
    s.blocks.splice(active + 1, 0, next + text.slice(off));
    rebuild(active + 1, next.length);
  } else if (e.key === 'Backspace' && collapsed && off === 0 && active > 0) {
    e.preventDefault();
    remember('edit');
    const prev = s.blocks[active - 1];
    s.blocks[active - 1] = prev + text;
    s.blocks.splice(active, 1);
    rebuild(active - 1, prev.length);
  } else if (e.key === 'ArrowUp' && collapsed && active > 0 && caretLine(el).first) {
    e.preventDefault(); activate(active - 1);
  } else if (e.key === 'ArrowDown' && collapsed && active < s.blocks.length - 1 && caretLine(el).last) {
    e.preventDefault(); activate(active + 1, 0);
  } else if (e.key === 'Escape') {
    deactivate();
  }
});

doc.addEventListener('mousedown', e => {
  const el = e.target.closest('.blk');
  if (el?.classList.contains('active') && el.classList.contains('table')) {
    // Inside a cell the browser places the caret; anywhere else in the block keeps the grid
    // live rather than letting the cell lose focus and close it.
    if (e.target.closest('.cell')) return;
    e.preventDefault();
    const c = e.target.closest('td, th')?.querySelector('.cell');
    if (c) { c.focus(); setCaret(c, c.textContent.length); }
    return;
  }
  if (!el || el.classList.contains('active')) return;
  const i = +el.dataset.i, s = script();
  const gutter = el.classList.contains('check') && e.clientX - el.getBoundingClientRect().left < 34;
  if (e.target.matches('input[type=checkbox]') || gutter) {
    e.preventDefault();
    remember('edit');
    s.blocks[i] = s.blocks[i].replace(/^([-*] \[)( |x|X)\]/, (_, a, b) => `${a}${b === ' ' ? 'x' : ' '}]`);
    paint(el, s.blocks[i], false); changed(); return;
  }
  if (e.target.closest('a[href]') && (e.metaKey || e.ctrlKey)) return; // ⌘-click follows a link
  e.preventDefault();
  // The caret lands on the character clicked. Measured in the formatted face before it turns
  // into source, then mapped across the markers the source face adds.
  activate(i, clickToSource(el, s.blocks[i], e));
});
// How many characters of an element's text lie before a point, or null if it is not in it.
function pointInText(el, x, y) {
  let node, offset;
  if (document.caretPositionFromPoint) { const p = document.caretPositionFromPoint(x, y); node = p?.offsetNode; offset = p?.offset; }
  else if (document.caretRangeFromPoint) { const r = document.caretRangeFromPoint(x, y); node = r?.startContainer; offset = r?.startOffset; }
  if (!node || !el.contains(node)) return null;
  const r = document.createRange();
  r.selectNodeContents(el); r.setEnd(node, offset);
  return r.toString().length;
}
// The formatted text is the source with its markers taken out, so its characters appear in the
// source in order: walk both and land on the source character the click was before. The walk
// starts after the block's own prefix ("- [x] ", "# ", a code fence), so a letter in the prefix
// can't be mistaken for one in the text. It stays a matching heuristic inside the text: a click
// next to an inline marker can land either side of it.
function sourceOffset(src, shown, at, from = 0) {
  if (at >= shown.length) return src.length;
  let i = from;
  for (let j = 0; j < at && i < src.length; i++) if (src[i] === shown[j]) j++;
  while (i < src.length && src[i] !== shown[at]) i++;
  return Math.min(i, src.length);
}
// Where in the source a click on a formatted block belongs.
function clickToSource(el, src, e) {
  const k = classify(src);
  if (k.type === 'table') {
    // A table maps cell by cell: the row and column clicked, then the place within that cell.
    const cell = e.target.closest('td, th'), tr = cell?.parentElement;
    if (!cell) return undefined;
    const lines = src.split('\n');
    const bodyLines = lines.map((l, n) => n).filter(n => n > 1 && lines[n].trim() && lines[n].trim() !== '|');
    const n = tr.parentElement.tagName === 'THEAD' ? 0 : bodyLines[tr.rowIndex - 1];
    if (n == null) return undefined;
    const line = lines[n], lineStart = lines.slice(0, n).reduce((a, l) => a + l.length + 1, 0);
    const pipes = [...line.matchAll(PIPE)].map(m => m.index);
    const start = pipes[cell.cellIndex], end = pipes[cell.cellIndex + 1] ?? line.length;
    if (start == null) return lineStart + line.length;
    const raw = line.slice(start + 1, end), lead = raw.length - raw.trimStart().length;
    const at = pointInText(cell, e.clientX, e.clientY);
    return lineStart + start + 1 + lead + (at == null ? 0 : sourceOffset(raw.trim(), cell.textContent, at));
  }
  const at = pointInText(el, e.clientX, e.clientY);
  if (at == null) return undefined;
  const from = k.type === 'code' ? src.indexOf('\n') + 1 : k.pre.length;
  return sourceOffset(src, el.textContent, at, from);
}
doc.addEventListener('click', e => { if (e.target.closest('a') && !(e.metaKey || e.ctrlKey)) e.preventDefault(); });
$('#editor-scroll').addEventListener('mousedown', e => {
  // A block that handled the press may have repainted, leaving e.target detached from it.
  if (e.defaultPrevented || e.target.closest('.blk')) return;
  const s = script();
  if (!s) return;
  e.preventDefault();
  if (s.blocks[s.blocks.length - 1] !== '') { s.blocks.push(''); renderDoc(); }
  activate(s.blocks.length - 1);
});
doc.addEventListener('focusout', e => { if (!doc.contains(e.relatedTarget)) setTimeout(() => { if (!doc.contains(document.activeElement)) deactivate(); }, 0); });

// ---------- a table, edited cell by cell ----------
// While a table is the active block it is a grid: each cell is its own small editor showing its
// source (markers dimmed, as any active block does), and the block's text is rebuilt from the
// cells as you type. A typed | is stored as \| so it can't split a cell, and a pasted line break
// becomes a space. Tab and ⇧Tab move along the row and on to the next; Tab in the last cell adds
// a row. Enter starts a row below (below the header, never between it and the separator); Enter
// on an empty row leaves the table, as before. ↑ ↓ move within the column and out of the table
// at either end; ← → at a cell's edge move to the next cell. ⌥⌘→ adds a column after this one
// and ⌥⌘⌫ removes it. ⌫ in an empty row removes the row, and in an empty table removes it.
const rowLines = lines => lines.map((_, n) => n).filter(n => n === 0 || (n > 1 && lines[n].trim() && lines[n].trim() !== '|'));
const lineStart = (lines, n) => lines.slice(0, n).reduce((a, l) => a + l.length + 1, 0);
// The table as rows of cell sources, every row as wide as the widest, so no cell is dropped.
function parseTable(t) {
  const lines = t.split('\n'), rows = rowLines(lines).map(n => cells(lines[n]));
  const width = Math.max(...rows.map(r => r.length));
  const pad = (r, fill) => r.length < width ? [...r, ...Array(width - r.length).fill(fill)] : r;
  return { sep: pad(cells(lines[1]), '---'), rows: rows.map(r => pad(r, '')) };
}
const tableText = ({ sep, rows }) => [rows[0], sep, ...rows.slice(1)].map(r => `| ${r.join(' | ')} |`).join('\n');
// Which cell a source offset falls in, and where in it; and back again.
function cellAt(t, off) {
  const lines = t.split('\n'), rl = rowLines(lines), n = t.slice(0, off).split('\n').length - 1;
  const r = Math.max(0, rl.findLastIndex(x => x <= n)), line = lines[rl[r]];
  const at = rl[r] === n ? off - lineStart(lines, n) : line.length;
  const pipes = [...line.matchAll(PIPE)].map(m => m.index);
  const c = Math.max(0, Math.min(pipes.filter(p => p < at).length - 1, cells(line).length - 1));
  const start = (pipes[c] ?? -1) + 1, raw = line.slice(start, pipes[c + 1] ?? line.length);
  const lead = raw.length - raw.trimStart().length;
  return { r, c, o: Math.max(0, Math.min(at - start - lead, raw.trim().length)) };
}
function sourceAt(t, r, c, o) {
  const lines = t.split('\n'), n = rowLines(lines)[r] ?? 0, line = lines[n], from = lineStart(lines, n);
  const pipes = [...line.matchAll(PIPE)].map(m => m.index);
  if (pipes[c] == null) return from + line.length;
  const raw = line.slice(pipes[c] + 1, pipes[c + 1] ?? line.length), lead = raw.length - raw.trimStart().length;
  return from + pipes[c] + 1 + lead + Math.min(o, raw.trim().length);
}
function paintGrid(el, t) {
  const { sep, rows } = parseTable(t);
  const align = sep.map(c => c.startsWith(':') && c.endsWith(':') ? 'center' : c.endsWith(':') ? 'right' : '');
  const row = (r, ri) => `<tr>${r.map((c, ci) => { const tag = ri ? 'td' : 'th';
    return `<${tag}${align[ci] ? ` style="text-align:${align[ci]}"` : ''}><span class="cell" data-r="${ri}" data-c="${ci}" contenteditable="plaintext-only" role="textbox" aria-label="${ri ? `Row ${ri}` : 'Header'}, column ${ci + 1}">${inline(c, true)}</span></${tag}>`; }).join('')}</tr>`;
  el.innerHTML = `<table><thead>${row(rows[0], 0)}</thead><tbody>${rows.slice(1).map((r, i) => row(r, i + 1)).join('')}</tbody></table>`;
}
const activeCell = () => { const c = document.activeElement?.closest?.('.cell'); return c && doc.children[active]?.contains(c) ? c : null; };
function focusCell(el, r, c, o) {
  const cell = el.querySelector(`.cell[data-r="${r}"][data-c="${c}"]`);
  if (!cell) return;
  cell.focus({ preventScroll: true });
  setCaret(cell, o == null ? cell.textContent.length : o);
  cell.scrollIntoView({ block: 'nearest', inline: 'nearest' });
}
// Where the caret is, in source characters, for undo to put it back.
function blockOffset() {
  const el = doc.children[active], cell = activeCell();
  if (!cell) return caretOffset(el);
  // The stored cell is trimmed, so a caret counted over the cell's text loses its leading spaces.
  const text = cell.textContent, lead = text.length - text.trimStart().length;
  return sourceAt(script().blocks[active], +cell.dataset.r, +cell.dataset.c, Math.max(0, (caretOffset(cell) ?? 0) - lead));
}
function tableInput() {
  const s = script(), cell = activeCell();
  if (!cell) return;
  let off = caretOffset(cell) ?? 0;
  const typed = cell.textContent.replace(/\n/g, ' '), at = off;
  const src = typed.replace(PIPE, (m, i) => { if (i < at) off++; return '\\|'; });
  const t = parseTable(s.blocks[active]);
  t.rows[+cell.dataset.r][+cell.dataset.c] = src;
  s.blocks[active] = tableText(t);
  cell.innerHTML = inline(src, true);
  setCaret(cell, off);
  changed();
}
function tableKey(e, s, el, text) {
  if (e.key === 'Escape') { deactivate(); return; }
  const cell = activeCell();
  if (!cell) return;
  const r = +cell.dataset.r, c = +cell.dataset.c, o = caretOffset(cell) ?? 0, len = cell.textContent.length;
  const collapsed = getSelection().isCollapsed, t = parseTable(text), rows = t.rows.length, cols = t.rows[0].length;
  const go = (r2, c2, o2) => focusCell(el, r2, c2, o2);
  const write = (r2, c2, o2) => { s.blocks[active] = tableText(t); paintGrid(el, s.blocks[active]); go(r2, c2, o2); changed(); };
  const empty = row => row.every(x => !x.trim());
  if (e.altKey && e.metaKey && e.key === 'ArrowRight') {
    e.preventDefault(); remember('edit');
    t.rows.forEach(row => row.splice(c + 1, 0, '')); t.sep.splice(c + 1, 0, '---');
    return write(r, c + 1, 0);
  }
  if (e.altKey && e.metaKey && e.key === 'Backspace') {
    e.preventDefault();
    if (cols < 2) return;
    remember('edit');
    t.rows.forEach(row => row.splice(c, 1)); t.sep.splice(c, 1);
    return write(r, Math.min(c, cols - 2));
  }
  if (e.key === 'Tab') {
    if (e.shiftKey && r === 0 && c === 0) return;   // ⇧Tab from the first cell leaves the table, as Tab leaves any field
    e.preventDefault();
    if (e.shiftKey) return c > 0 ? go(r, c - 1) : go(r - 1, cols - 1);
    if (c < cols - 1) return go(r, c + 1);
    if (r < rows - 1) return go(r + 1, 0);
    remember('edit'); t.rows.push(Array(cols).fill(''));
    return write(r + 1, 0, 0);
  }
  if (e.key === 'Enter') {
    e.preventDefault(); remember('edit');
    if (r > 0 && empty(t.rows[r])) {
      t.rows.splice(r, 1); s.blocks[active] = tableText(t);
      s.blocks.splice(active + 1, 0, '');
      return rebuild(active + 1, 0);
    }
    t.rows.splice(r + 1, 0, Array(cols).fill(''));
    return write(r + 1, 0, 0);
  }
  if (e.key === 'Backspace' && collapsed && o === 0 && c === 0) {
    if (r > 0 && empty(t.rows[r])) {
      e.preventDefault(); remember('edit');
      t.rows.splice(r, 1);
      return write(r - 1, cols - 1);
    }
    if (r === 0 && t.rows.every(empty)) {
      e.preventDefault(); remember('edit');
      s.blocks[active] = '';
      return rebuild(active, 0);
    }
    return;
  }
  if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
    // Only from a cell's first or last line, as in any block: a wrapped cell moves within itself.
    const up = e.key === 'ArrowUp', line = caretLine(cell);
    if (e.shiftKey || e.metaKey || e.altKey || e.ctrlKey || !(up ? line.first : line.last)) return;
    e.preventDefault();
    const r2 = r + (up ? -1 : 1);
    if (r2 >= 0 && r2 < rows) return go(r2, c, Math.min(o, t.rows[r2][c].length));
    if (r2 < 0 && active > 0) return activate(active - 1);
    if (r2 >= rows && active < s.blocks.length - 1) return activate(active + 1, 0);
    return;
  }
  const plain = !e.shiftKey && !e.metaKey && !e.altKey && !e.ctrlKey;
  if (e.key === 'ArrowLeft' && collapsed && plain && o === 0) {
    e.preventDefault();
    if (c > 0) go(r, c - 1); else if (r > 0) go(r - 1, cols - 1); else if (active > 0) activate(active - 1);
    return;
  }
  if (e.key === 'ArrowRight' && collapsed && plain && o === len) {
    e.preventDefault();
    if (c < cols - 1) go(r, c + 1, 0); else if (r < rows - 1) go(r + 1, 0, 0); else if (active < s.blocks.length - 1) activate(active + 1, 0);
  }
}

// ---------- page mode: continuous, A4 or US Letter (D-314) ----------
const PAGE = { a4: { w: 794, h: 1123 }, letter: { w: 816, h: 1056 } }; // CSS px at 96 dpi
const MARGIN = 76, GAP = 28, PAPER_TOP = 40;

function applyMode() {
  const s = script(), paged = s && s.mode !== 'continuous';
  $('#paper').className = 'paper ' + (paged ? 'paged' : 'continuous');
  $('#editor-pane').classList.toggle('paged', !!paged);
  document.querySelectorAll('#page-mode button').forEach(b => b.setAttribute('aria-checked', String(!!s && b.dataset.mode === s.mode)));
  paginate();
}

function paginate() {
  const s = script(), paper = $('#paper'), sheets = $('#sheets');
  sheets.innerHTML = '';
  [...doc.children].forEach(el => { el.style.marginTop = ''; });
  if (!s || s.mode === 'continuous') { paper.style.width = ''; paper.style.zoom = ''; doc.style.padding = ''; doc.style.minHeight = ''; return; }
  const { w, h } = PAGE[s.mode], content = h - 2 * MARGIN, stride = h + GAP;
  paper.style.width = w + 'px';
  doc.style.padding = `${MARGIN}px`;
  // Push any block that would cross a page edge onto the next page.
  for (const el of doc.children) {
    const y = el.offsetTop - MARGIN, page = Math.floor(y / stride), inPage = y - page * stride;
    if (inPage > 0 && inPage + el.offsetHeight > content) {
      const base = parseFloat(getComputedStyle(el).marginTop) || 0;
      el.style.marginTop = base + (stride - inPage) + 'px';
    }
  }
  const last = doc.lastElementChild, end = last ? last.offsetTop + last.offsetHeight - MARGIN : 0;
  const pages = Math.max(1, Math.floor(end / stride) + 1);
  doc.style.minHeight = pages * stride - GAP + 'px';
  for (let p = 0; p < pages; p++) {
    const sh = document.createElement('div');
    sh.className = 'sheet'; sh.style.top = PAPER_TOP + p * stride + 'px'; sh.style.height = h + 'px';
    sh.innerHTML = `<div class="num">${p + 1}</div>`;
    sheets.append(sh);
  }
  const avail = $('#editor-pane').clientWidth - 48;
  paper.style.zoom = avail < w ? (avail / w).toFixed(3) : '';
  if (s.pageCount !== pages) { s.pageCount = pages; save(); renderScripts(); }
}

document.querySelectorAll('#page-mode button').forEach(b => b.addEventListener('click', () => {
  const s = script(); if (!s) return;
  s.mode = b.dataset.mode; save(); applyMode(); renderScripts();
}));

// ---------- selecting, creating and changing kind (D-313) ----------
function open(id) {
  current = id; save(); renderScripts(); renderDoc();
  Object.assign(edits, { undo: [], redo: [], typing: 0, id });
  $('#script-heading').textContent = titleOf(script());
}
$('#scripts').addEventListener('click', e => { const c = e.target.closest('[data-script]'); if (c) open(c.dataset.script); });
// A Take's lines become blocks, except that a fenced code block or a table stays one block.
// Return is the line break (owner, 2026-10-02: the editor is WYSIWYG), so one line is one block
// and markdown's two-space line break means nothing here.
function linesToBlocks(text) {
  const out = [];
  let fence = null;
  for (const line of text.split('\n')) {
    const prev = out.at(-1);
    if (fence !== null) { fence += '\n' + line; if (/^```\s*$/.test(line)) { out.push(fence); fence = null; } }
    else if (/^```/.test(line)) fence = line;
    else if (prev != null && /^\|/.test(line) && (isTable(prev + '\n' + line) || isTable(prev))) out[out.length - 1] = prev + '\n' + line;
    else out.push(line);
  }
  if (fence !== null) out.push(fence);
  return out;
}
// The other way: one block per line, code blocks and tables keeping their own lines.
const blocksToText = blocks => blocks.join('\n');
function newScript(blocks = ['']) {
  const s = { id: 's' + Date.now(), at: new Date().toISOString().slice(0, 10), mode: newScriptMode(), blocks };
  scripts.push(s); open(s.id); activate(0);
}
$('#new-script').addEventListener('click', () => newScript());

const ctx = $('#ctx');
// Built per target: a Take's menu comes from takeMenu() in takes.js; a Script has one item.
function openCtx(target, x, y) {
  const take = target.closest('[data-take]'), scr = target.closest('[data-script]'), info = target.closest('[data-copy-info]');
  if (!take && !scr && !info) return false;
  // The copy goes back to the version line, so a keyboard user keeps their place.
  const items = info ? [['Copy version and device info', () => { navigator.clipboard?.writeText(supportInfo()); info.focus(); }]]   // settings.js
    : take ? takeMenu(take.dataset.take)
    : isBlank(takeFromScript(scripts.find(x => x.id === scr.dataset.script))) ? []   // a blank Take is never kept
    : [['Make this a Take', () => scriptToTake(scr.dataset.script)]];
  if (!items.length) return false;
  ctx.innerHTML = '';
  for (const [label, act, kind] of items) {
    const li = document.createElement('li'), b = document.createElement('button');
    b.textContent = label; b.type = 'button';
    if (kind === 'danger') {
      // Delete asks through the same alert as everywhere else (DeleteConfirmation on iOS).
      b.className = 'danger';
      b.addEventListener('click', () => {
        const t = takes.find(x => x.id === take.dataset.take);
        ctx.hidden = true;
        if (asksWhichToDelete(t)) askWhichToDelete(t);
        else if (settings.confirmDelete) askDelete(t);
        else deleteTake(t.id);
        refocus();   // a11y.js: deferred while an alert is open; otherwise the card is gone and it just clears
      });
    } else b.addEventListener('click', () => { ctx.hidden = true; act(); refocus(); });   // refocus: a11y.js
    li.append(b); ctx.append(li);
  }
  ctx.hidden = false;
  ctx.style.left = Math.min(x, innerWidth - 220) + 'px'; ctx.style.top = Math.min(y, innerHeight - 44 * items.length - 16) + 'px';
  return true;
}
document.addEventListener('contextmenu', e => { if (openCtx(e.target, e.clientX, e.clientY)) e.preventDefault(); });
// Touch has no right-click: a long press (500ms, under 10px of movement) opens the same menu.
let press = null;
document.addEventListener('pointerdown', e => {
  if (e.pointerType === 'mouse' || e.target.closest('.iris-wrap')) return;   // holding an Iris makes the Obie
  const { target, clientX: x, clientY: y } = e;
  press = { x, y, t: setTimeout(() => { press = null; openCtx(target, x, y); }, 500) };
});
document.addEventListener('pointermove', e => { if (press && Math.hypot(e.clientX - press.x, e.clientY - press.y) > 10) { clearTimeout(press.t); press = null; } });
document.addEventListener('pointerup', () => { if (press) { clearTimeout(press.t); press = null; } });
document.addEventListener('mousedown', e => { if (!ctx.contains(e.target)) ctx.hidden = true; });
function scriptToTake(id) {
  const s = scripts.find(x => x.id === id);
  scripts = scripts.filter(x => x !== s);
  // The text moves as it is: "- [ ]" lines become checklist items, the rest stays text (D-313).
  takes.push(takeFromScript(s));
  if (current === s.id) current = scripts[0] ? scripts[0].id : null;
  save(); saveTakes(); renderTakes(); renderScripts(); renderDoc();
  $('#script-heading').textContent = titleOf(script());
}

// ---------- view options and search ----------
$('#search-btn').addEventListener('click', () => {
  const row = $('#search-row'); row.hidden = !row.hidden; $('#search-btn').classList.toggle('on', !row.hidden);
  if (!row.hidden) $('#search').focus(); else { query = ''; $('#search').value = ''; renderScripts(); }
});
$('#search').addEventListener('input', e => { query = e.target.value.trim().toLowerCase(); renderScripts(); });

// ---------- layout: each section left, middle or right, or hidden ----------
// Default: Dailies left, the Script area in the middle, Scripts right. The Script
// area takes the spare width; the others keep their own, and resize by dragging.
const app = $('#app');
const PANE = { dailies: $('#sidebar'), editor: $('#editor-pane'), scripts: $('#scriptlist') };
const SLOTS = ['left', 'middle', 'right'];
const LIMIT = { dailies: [300, 640], scripts: [260, 520], editor: [420, 1400] };
let layout = Object.assign({ dailies: 'left', editor: 'middle', scripts: 'right' }, store.get('layout', {}));
const lastPos = Object.assign({ dailies: 'left', editor: 'middle', scripts: 'right' }, store.get('lastPos', {}));
// Dailies opens at the iPhone's height-to-width proportion (393 x 852), clamped.
const widths = Object.assign({ dailies: Math.round(Math.min(560, Math.max(320, (innerHeight - 44) * 393 / 852))), scripts: 340, editor: 760 }, store.get('widths', {}));

function applyLayout() {
  const order = SLOTS.map(p => Object.keys(layout).find(k => layout[k] === p)).filter(Boolean);
  const flex = order.includes('editor') ? 'editor' : order[order.length >> 1];
  app.querySelectorAll('.resizer').forEach(r => r.remove());
  const cols = [];
  for (const k in PANE) PANE[k].hidden = !order.includes(k);
  order.forEach((k, i) => {
    if (i > 0) {
      const left = order[i - 1], target = left !== flex ? left : k;
      const r = document.createElement('div');
      r.className = 'resizer'; r.setAttribute('role', 'separator'); r.setAttribute('aria-orientation', 'vertical');
      r.style.gridColumn = cols.length + 1; cols.push('1px');
      app.append(r); dragger(r, target, target === left ? 1 : -1);
    }
    PANE[k].style.gridColumn = cols.length + 1;
    cols.push(k === flex ? 'minmax(0, 1fr)' : widths[k] + 'px');
  });
  app.style.gridTemplateColumns = cols.join(' ');
  document.querySelectorAll('#layout-pop .seg').forEach(seg => {
    seg.innerHTML = [...SLOTS, 'hidden'].map(p => `<button data-p="${p}" class="${layout[seg.dataset.pane] === p ? 'on' : ''}">${p === 'hidden' ? 'Hide' : p[0].toUpperCase() + p.slice(1)}</button>`).join('');
  });
  store.set('layout', layout); store.set('lastPos', lastPos);
  paginate();
}

function place(k, p) {
  const visible = Object.keys(layout).filter(x => layout[x] !== 'hidden');
  if (p === 'hidden') {
    if (visible.length === 1 && visible[0] === k) return; // always keep one section on screen
    if (layout[k] !== 'hidden') lastPos[k] = layout[k];
    layout[k] = 'hidden';
  } else {
    const other = Object.keys(layout).find(x => x !== k && layout[x] === p);
    const from = layout[k];
    layout[k] = p;
    if (other) {
      // Swap into the slot this section left, or the first free one, or hide.
      const free = SLOTS.find(s => !Object.values(layout).includes(s));
      layout[other] = from !== 'hidden' ? from : (free || 'hidden');
      if (layout[other] === 'hidden') lastPos[other] = p;
    }
  }
  applyLayout();
}
function toggleHide(k) {
  if (layout[k] !== 'hidden') return place(k, 'hidden');
  const free = SLOTS.find(s => !Object.values(layout).includes(s));
  place(k, Object.values(layout).includes(lastPos[k]) && free ? free : lastPos[k]);
}

function dragger(handle, k, sign) {
  handle.addEventListener('pointerdown', e => {
    e.preventDefault();
    handle.setPointerCapture(e.pointerId); handle.classList.add('dragging');
    const start = e.clientX, startW = PANE[k].getBoundingClientRect().width;
    const move = ev => {
      widths[k] = Math.round(Math.min(LIMIT[k][1], Math.max(LIMIT[k][0], startW + sign * (ev.clientX - start))));
      const cols = app.style.gridTemplateColumns.split(' ');
      cols[+PANE[k].style.gridColumn - 1] = widths[k] + 'px';
      app.style.gridTemplateColumns = cols.join(' ');
      store.set('widths', widths); paginate();
    };
    const up = () => { handle.classList.remove('dragging'); handle.removeEventListener('pointermove', move); handle.removeEventListener('pointerup', up); };
    handle.addEventListener('pointermove', move); handle.addEventListener('pointerup', up);
  });
}

$('#tb-layout').addEventListener('click', () => {
  const p = $('#layout-pop'); p.hidden = !p.hidden; $('#tb-layout').setAttribute('aria-expanded', String(!p.hidden));
});
$('#layout-pop').addEventListener('click', e => { const b = e.target.closest('button[data-p]'); if (b) place(b.closest('.seg').dataset.pane, b.dataset.p); });
$('#tb-page').addEventListener('click', () => {
  const p = $('#page-pop'); p.hidden = !p.hidden; $('#tb-page').setAttribute('aria-expanded', String(!p.hidden));
});
document.addEventListener('mousedown', e => {
  if (!e.target.closest('#layout-pop, #tb-layout')) { $('#layout-pop').hidden = true; $('#tb-layout').setAttribute('aria-expanded', 'false'); }
  if (!e.target.closest('#page-pop, #tb-page')) { $('#page-pop').hidden = true; $('#tb-page').setAttribute('aria-expanded', 'false'); }
});
document.addEventListener('keydown', e => {
  // Not while first run covers the window: the change would land unseen.
  if (!(e.metaKey && e.ctrlKey) || document.body.classList.contains('first-running')) return;
  if (e.key.toLowerCase() === 's') { e.preventDefault(); toggleHide('dailies'); }
  if (e.key.toLowerCase() === 'l') { e.preventDefault(); toggleHide('scripts'); }
});
addEventListener('resize', debounce(paginate, 100));

// ---------- Scene: follows the system unless chosen ----------
const scenes = ['auto', 'night', 'daylight'];
let scene = store.get('scene', 'auto');
const mq = matchMedia('(prefers-color-scheme: light)');
function applyScene() {
  document.documentElement.dataset.scene = scene === 'auto' ? (mq.matches ? 'daylight' : 'night') : scene;
  $('#tb-scene').title = `Scene: ${scene === 'auto' ? 'follows the system' : scene === 'night' ? 'Night' : 'Daylight'}`;
}
mq.addEventListener('change', applyScene);
$('#tb-scene').addEventListener('click', () => { scene = scenes[(scenes.indexOf(scene) + 1) % 3]; store.set('scene', scene); applyScene(); });

// ---------- the light is fixed in the world ----------
// Each Iris's catchlight turns with where it sits on screen: lit from the side (west)
// at the top, from above (north) at the bottom, 26° either way of ten o'clock
// (IrisDepth.specularTravelDegrees). Reduce Motion parks every light at ten o'clock.
const still = matchMedia('(prefers-reduced-motion: reduce)');
let glintFrame = 0;
function turnGlints() {
  glintFrame = 0;
  const h = innerHeight;
  document.querySelectorAll('.iris-wrap').forEach(w => {
    const r = w.getBoundingClientRect();
    const t = Math.min(1, Math.max(0, (r.top + r.height / 2) / h));
    const deg = still.matches ? 0 : (t - 0.5) * 2 * 26;
    w.querySelector('.glints')?.setAttribute('transform', `rotate(${deg.toFixed(1)} 20 20)`);
  });
}
const queueGlints = () => { if (!glintFrame) glintFrame = requestAnimationFrame(turnGlints); };
document.querySelectorAll('.timeline').forEach(t => t.addEventListener('scroll', queueGlints, { passive: true }));
addEventListener('resize', queueGlints);
still.addEventListener('change', queueGlints);
new MutationObserver(queueGlints).observe(document.querySelector('#app'), { childList: true, subtree: true });

// ---------- start ----------
applyScene(); applyLayout();
if (!script() && scripts[0]) current = scripts[0].id;
renderScripts(); renderDoc();   // renderTakes runs at the end of takes.js
$('#script-heading').textContent = script() ? titleOf(script()) : '';
document.fonts.ready.then(paginate);
