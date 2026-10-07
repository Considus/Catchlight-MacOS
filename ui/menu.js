'use strict';
// The menu bar, as data. Every command the app offers from a menu, its shortcut on each desktop,
// when it can run and what it does, in one table. The native shells (D-318) build their menus
// from `catchlightMenu.model()`, ask again before a menu opens so labels, ticks and greyed items
// are current, and call `catchlightMenu.run(id)` when one is chosen. In a browser there is no
// menu bar, so this file binds the same shortcuts itself, and `?menu` draws a stand-in bar to
// look at. Loaded last: it reaches into every other file.
//
// Shortcuts are written once, portably. `Mod` is ⌘ on the Mac and Ctrl elsewhere; `Ctrl` is the
// Mac's ⌃ and is only used in Mac-only keys; `Alt` is ⌥ / Alt. A key differs by platform only
// where the conventions do (redo, quit, the pane toggles). `role` marks an item the platform
// supplies itself (Cut, Copy, Hide, Quit…): the shell wires it to the OS and this file never runs it.
//
// Never Ctrl+Alt on Windows or Linux: it is AltGr on European keyboards, so Ctrl+Alt+0 would
// stop someone typing "}", and Ctrl+Alt+Backspace can end a Linux session. A table's column keys
// are the Mac's alone; elsewhere the Format menu does it.
// iOS has no keyboard commands, so nothing here mirrors it; each choice follows the platform's
// own apps (Notes, Reminders, Pages on the Mac). `menuCollisions()` checks no two items share a key.

const PLAT = PLATFORM === PLATFORMS.windows ? 'windows' : PLATFORM === PLATFORMS.linux ? 'linux' : 'mac';
const SEP = { sep: true };

// ---------- what the commands act on ----------
const ready = () => !document.body.classList.contains('first-running') && !alertBox.open && !document.querySelector('.reset-done');
// Free: nothing that owns the keyboard is open. The Focus-ring, the reminder picker, the Shot List
// and Settings each close themselves first, as their own keys already do (takes.js ⌘S).
const free = () => ready() && !focusRing && !reminderFor && !shotListOpen() && sheet.hidden;
const cardTake = () => { const c = document.activeElement?.closest?.('[data-take]'); return c ? takes.find(t => t.id === c.dataset.take) : null; };
const takeInHand = () => draft || cardTake();                     // the Take being edited, else the focused card
const savedTake = () => draft ? takes.find(t => t.id === original?.id) : cardTake();
// A block Format can act on: not a table (the grid has its own), a code block or a rule, whose
// text isn't markdown to style.
const scriptBlock = () => active >= 0 && script() && !['table', 'code', 'hr'].includes(classify(script().blocks[active]).type) ? doc.children[active] : null;
const blockType = () => scriptBlock() ? classify(script().blocks[active]).type : null;   // nothing ticked with no block in hand
const inGrid = () => !!(active >= 0 && activeCell());

// ---------- Format: the Script editor's active block ----------
function selectRange(el, a, b) {
  const at = off => {
    const w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    let n, left = off;
    while ((n = w.nextNode())) { if (left <= n.length) return [n, left]; left -= n.length; }
    return [el, el.childNodes.length];
  };
  const r = document.createRange();
  r.setStart(...at(a)); r.setEnd(...at(b));
  const sel = getSelection(); sel.removeAllRanges(); sel.addRange(r);
}
function selectionIn(el) {
  const sel = getSelection();
  if (!sel.rangeCount || !el.contains(sel.anchorNode)) return null;
  const len = (node, off) => { const r = document.createRange(); r.selectNodeContents(el); r.setEnd(node, off); return r.toString().length; };
  const a = len(sel.anchorNode, sel.anchorOffset), b = len(sel.focusNode, sel.focusOffset);
  return [Math.min(a, b), Math.max(a, b)];
}
// Bold, italic, strikethrough and code wrap the selection in their markers, or unwrap it.
function wrapSelection(mark) {
  const el = scriptBlock(), s = script();
  const range = el && selectionIn(el);
  if (!range) return;
  const t = s.blocks[active], [a, b] = range, n = mark.length;
  remember('edit');
  // A lone * next to another * is half of a ** (bold), not italic's own marker.
  const lone = mark !== '*' || (t[a - n - 1] !== '*' && t[b + n] !== '*');
  const on = lone && t.slice(a - n, a) === mark && t.slice(b, b + n) === mark;
  s.blocks[active] = on ? t.slice(0, a - n) + t.slice(a, b) + t.slice(b + n) : t.slice(0, a) + mark + t.slice(a, b) + mark + t.slice(b);
  paint(el, s.blocks[active], true);
  selectRange(el, on ? a - n : a + n, on ? b - n : b + n);
  changed();
}
// A heading, list, checklist or quote replaces the block's own prefix; choosing the one it
// already has turns it back into a paragraph.
const PREFIX = { p: '', h1: '# ', h2: '## ', h3: '### ', li: '- ', 'li ol': '1. ', check: '- [ ] ', quote: '> ' };
function setBlock(type) {
  const el = scriptBlock(), s = script();
  if (!el) return;
  const t = s.blocks[active], k = classify(t), off = caretOffset(el) ?? t.length;
  const to = k.type === type ? 'p' : type, pre = PREFIX[to];
  remember('edit');
  s.blocks[active] = pre + t.slice(k.pre.length);
  paint(el, s.blocks[active], true);
  setCaret(el, Math.max(pre.length, off - k.pre.length + pre.length));
  changed();
}
function insertTable() {
  const s = script();
  if (!s || active < 0) return;
  remember('edit');
  const table = '| Column | Column |\n| --- | --- |\n|  |  |';
  if (s.blocks[active].trim() === '') s.blocks[active] = table; else s.blocks.splice(++active, 0, table);
  rebuild(active, sourceAt(table, 0, 0, 0));
}
function gridEdit(fn) {
  const cell = activeCell(), s = script(), el = doc.children[active];
  if (!cell) return;
  const t = parseTable(s.blocks[active]), r = +cell.dataset.r, c = +cell.dataset.c;
  remember('edit');
  const [r2, c2] = fn(t, r, c);
  s.blocks[active] = tableText(t); paintGrid(el, s.blocks[active]); focusCell(el, r2, c2, 0); changed();
}

// ---------- Take ----------
function deleteInHand() {
  const t = savedTake();
  if (!t || refuseHeld(t.id)) return;
  if (draft) discardEdit();
  if (asksWhichToDelete(t)) askWhichToDelete(t); else if (settings.confirmDelete) askDelete(t); else deleteTake(t.id);
}
// A command on a focused card repaints the list; focus goes back to the card's replacement (a11y.js).
function onCard(fn) { const t = cardTake(); if (refuseHeld(t.id)) return; returnFocusTo = { id: t.id }; fn(t); refocus(); }
// The focused card waits for a conflict choice, so nothing in the Take menu changes it.
const cardHeld = () => !draft && isHeld(cardTake()?.id);
function toggleImportant() {
  if (draft) { draft.isImportant = !draft.isImportant; if (!draft.isImportant) noteFloor(draft); paintIris(); paintBar(); return; }
  onCard(t => { t.isImportant = !t.isImportant; if (!t.isImportant) noteFloor(t); touch(t); });
}
function markDone() {
  if (draft) { $('#eb-done').click(); return; }
  onCard(t => { toggleDone(t); touch(t); });
}
function showAbout() { openSettings(); subStack.push('about'); paintSettings(); }
function setScene(s) { scene = s; store.set('scene', scene); applyScene(); }
function setPage(mode) { const s = script(); if (!s || refuseHeld(s.id, 'Script')) return; s.mode = mode; save(); applyMode(); renderScripts(); }
function dockTo(mode) {
  if (draft) commitEdit();
  if (layout.dailies === 'hidden') toggleHide('dailies');
  storyboard = false;
  exitToResting();   // as Escape: no month, no Sequence toggles, no search text
  const field = $('#take-search'); if (field) field.value = '';
  storyboard = mode === 'storyboard';
  dock = mode === 'sequence' ? 'filtering' : mode === 'search' ? 'searching' : 'resting';
  renderTakes();
  if (mode === 'search') $('#take-search').focus();
}
const supportUrl = 'https://catchlight.app/support/?platform=' + PLATFORM.osName + '&app=0.1';

// ---------- the menus ----------
// Each item: id, label (text or a function of the moment), keys, enabled(), checked(), run(),
// or role for an OS item. `only` limits an item to some platforms.
const ITEMS = {
  about: { label: 'About Catchlight', run: showAbout },
  // Settings checks ready() rather than free(): the same item closes the sheet once it is open.
  settings: { label: PLAT === 'linux' ? 'Preferences' : 'Settings…', keys: { all: 'Mod+,' }, enabled: () => ready() && !focusRing && !reminderFor && !shotListOpen(), run: () => sheet.hidden ? openSettings() : closeSettings() },
  newTake: { label: 'New Take', keys: { all: 'Mod+N' }, enabled: () => free() && !draft, run: newTake },
  newScript: { label: 'New Script', keys: { all: 'Mod+Shift+N' }, enabled: free, run: () => newScript() },
  exportTakes: { label: 'Export Takes…', keys: { all: 'Mod+Shift+E' }, enabled: () => free() && takes.length > 0, run: () => exportTakes(takes) },
  importFile: { label: 'Import from a File…', enabled: free, run: importFromFile },   // settings.js
  importNotes: { label: 'Import Notes', enabled: () => free() && !!store.get('account', {})?.folder, run: importNotes },
  syncNow: { label: 'Sync Now', enabled: () => free() && settings.syncMode === 'manual' && !!store.get('account', {})?.folder, run: () => window.catchlightBridge ? catchlightBridge.sync('manual') : ask('Sync Now', "The sync runs in Core, through the shell, which doesn't exist yet.", [['OK', null, 'cancel']]) },
  undo: { label: 'Undo', keys: { all: 'Mod+Z' }, inPlace: true, run: () => active >= 0 ? undo() : document.execCommand('undo') },
  redo: { label: 'Redo', keys: { mac: 'Mod+Shift+Z', windows: 'Mod+Y', linux: 'Mod+Shift+Z' }, inPlace: true, run: () => active >= 0 ? redo() : document.execCommand('redo') },
  cut: { label: 'Cut', keys: { all: 'Mod+X' }, role: 'cut' },
  copy: { label: 'Copy', keys: { all: 'Mod+C' }, role: 'copy' },
  paste: { label: 'Paste', keys: { all: 'Mod+V' }, role: 'paste' },
  pasteMatch: { label: 'Paste and Match Style', keys: { mac: 'Mod+Alt+Shift+V', windows: 'Mod+Shift+V', linux: 'Mod+Shift+V' }, role: 'pasteAndMatchStyle' },
  selectAll: { label: 'Select All', keys: { all: 'Mod+A' }, role: 'selectAll' },
  find: { label: 'Find…', keys: { all: 'Mod+F' }, enabled: free, run: () => dockTo('search') },
  emoji: { label: 'Emoji & Symbols', keys: { mac: 'Ctrl+Mod+Space' }, role: 'emoji', only: ['mac'] },
  doneEditing: { label: 'Done Editing', keys: { all: 'Mod+S' }, enabled: () => free() && !!draft, run: commitEdit },
  markDone: { label: () => takeInHand() && isDone(takeInHand()) ? 'Mark Not Done' : 'Mark Done', keys: { all: 'Mod+Shift+C' }, enabled: () => free() && !!takeInHand() && !cardHeld() && canBeMarkedDone(takeInHand()), run: markDone },
  important: { label: () => takeInHand()?.isImportant ? 'Remove Important' : 'Make Important', keys: { all: 'Mod+Shift+I' }, enabled: () => free() && !!takeInHand() && !cardHeld() && !takeInHand().obie, run: toggleImportant },
  obie: { label: 'Make Obie', enabled: () => free() && !draft && !!cardTake() && !cardHeld() && !cardTake().obie && !storyboard, run: () => onCard(makeObie) },
  reminder: { label: () => draft?.reminder ? 'Edit Reminder…' : 'Add Reminder…', enabled: () => free() && !!draft, run: () => $('#eb-remind').click() },
  shotList: { label: 'Open Shot List', enabled: () => free() && !!draft && isTask(draft) && !shotListOpen(), run: openShotList },
  exportTake: { label: 'Export Take…', enabled: () => free() && !!takeInHand(), run: () => { if (draft) readRows(); exportTake(takeInHand()); } },
  deleteTake: { label: 'Delete Take', keys: { mac: 'Mod+Backspace', windows: 'Delete', linux: 'Delete' }, enabled: () => free() && !!cardTake() && !draft && !cardHeld(), run: deleteInHand },
  bold: { label: 'Bold', keys: { all: 'Mod+B' }, enabled: () => free() && !!scriptBlock(), run: () => wrapSelection('**') },
  italic: { label: 'Italic', keys: { all: 'Mod+I' }, enabled: () => free() && !!scriptBlock(), run: () => wrapSelection('*') },
  strike: { label: 'Strikethrough', keys: { all: 'Mod+Shift+X' }, enabled: () => free() && !!scriptBlock(), run: () => wrapSelection('~~') },
  code: { label: 'Code', keys: { all: 'Mod+E' }, enabled: () => free() && !!scriptBlock(), run: () => wrapSelection('`') },
  body: { label: 'Body', keys: { mac: 'Mod+Alt+0', windows: 'Mod+Shift+0', linux: 'Mod+Shift+0' }, enabled: () => free() && !!scriptBlock(), checked: () => blockType() === 'p', run: () => setBlock('p') },
  h1: { label: 'Title', keys: { mac: 'Mod+Alt+1', windows: 'Mod+Shift+1', linux: 'Mod+Shift+1' }, enabled: () => free() && !!scriptBlock(), checked: () => blockType() === 'h1', run: () => setBlock('h1') },
  h2: { label: 'Heading', keys: { mac: 'Mod+Alt+2', windows: 'Mod+Shift+2', linux: 'Mod+Shift+2' }, enabled: () => free() && !!scriptBlock(), checked: () => blockType() === 'h2', run: () => setBlock('h2') },
  h3: { label: 'Subheading', keys: { mac: 'Mod+Alt+3', windows: 'Mod+Shift+3', linux: 'Mod+Shift+3' }, enabled: () => free() && !!scriptBlock(), checked: () => blockType() === 'h3', run: () => setBlock('h3') },
  checklist: { label: 'Checklist', keys: { all: 'Mod+Shift+L' }, enabled: () => free() && !!scriptBlock(), checked: () => blockType() === 'check', run: () => setBlock('check') },
  bullets: { label: 'Bulleted List', keys: { all: 'Mod+Shift+7' }, enabled: () => free() && !!scriptBlock(), checked: () => blockType() === 'li', run: () => setBlock('li') },
  numbers: { label: 'Numbered List', keys: { all: 'Mod+Shift+9' }, enabled: () => free() && !!scriptBlock(), checked: () => blockType() === 'li ol', run: () => setBlock('li ol') },
  quote: { label: 'Quote', enabled: () => free() && !!scriptBlock(), checked: () => blockType() === 'quote', run: () => setBlock('quote') },
  table: { label: 'Table', enabled: () => free() && active >= 0 && !inGrid(), run: insertTable },
  addRow: { label: 'Add Row', enabled: () => free() && inGrid(), run: () => gridEdit((t, r) => { t.rows.splice(r + 1, 0, Array(t.rows[0].length).fill('')); return [r + 1, 0]; }) },
  addColumn: { label: 'Add Column', keys: { mac: 'Mod+Alt+Right' }, inPlace: true, enabled: () => free() && inGrid(), run: () => gridEdit((t, r, c) => { t.rows.forEach(row => row.splice(c + 1, 0, '')); t.sep.splice(c + 1, 0, '---'); return [r, c + 1]; }) },
  removeColumn: { label: 'Remove Column', keys: { mac: 'Mod+Alt+Backspace' }, inPlace: true, enabled: () => free() && inGrid() && parseTable(script().blocks[active]).rows[0].length > 1, run: () => gridEdit((t, r, c) => { t.rows.forEach(row => row.splice(c, 1)); t.sep.splice(c, 1); return [r, Math.min(c, t.rows[0].length - 1)]; }) },
  dailies: { label: 'Dailies', keys: { all: 'Mod+1' }, enabled: free, checked: () => !storyboard && dock === 'resting', run: () => dockTo('dailies') },
  storyboard: { label: 'Storyboard', keys: { all: 'Mod+2' }, enabled: free, checked: () => storyboard, run: () => dockTo('storyboard') },
  sequence: { label: 'Sequence', keys: { all: 'Mod+3' }, enabled: free, checked: () => dock === 'filtering', run: () => dockTo('sequence') },
  paneDailies: { label: () => layout.dailies === 'hidden' ? 'Show Dailies' : 'Hide Dailies', keys: { mac: 'Ctrl+Mod+S', windows: 'Mod+Shift+D', linux: 'Mod+Shift+D' }, enabled: free, run: () => toggleHide('dailies') },
  paneScripts: { label: () => layout.scripts === 'hidden' ? 'Show Scripts' : 'Hide Scripts', keys: { mac: 'Ctrl+Mod+L', windows: 'Mod+Shift+K', linux: 'Mod+Shift+K' }, enabled: free, run: () => toggleHide('scripts') },
  sceneAuto: { label: 'Match System', checked: () => scene === 'auto', run: () => setScene('auto') },
  sceneNight: { label: 'Night', checked: () => scene === 'night', run: () => setScene('night') },
  sceneDaylight: { label: 'Daylight', checked: () => scene === 'daylight', run: () => setScene('daylight') },
  pageContinuous: { label: 'Continuous', enabled: () => !!script(), checked: () => script()?.mode === 'continuous', run: () => setPage('continuous') },
  pageA4: { label: 'A4', enabled: () => !!script(), checked: () => script()?.mode === 'a4', run: () => setPage('a4') },
  pageLetter: { label: 'US Letter', enabled: () => !!script(), checked: () => script()?.mode === 'letter', run: () => setPage('letter') },
  fullScreen: { label: 'Enter Full Screen', keys: { mac: 'Ctrl+Mod+F', windows: 'F11', linux: 'F11' }, role: 'toggleFullScreen' },
  minimize: { label: 'Minimize', keys: { mac: 'Mod+M' }, role: 'minimize', only: ['mac'] },
  zoom: { label: 'Zoom', role: 'zoom', only: ['mac'] },
  front: { label: 'Bring All to Front', role: 'front', only: ['mac'] },
  closeWindow: { label: 'Close Window', keys: { mac: 'Mod+W' }, role: 'close', only: ['mac'] },
  hide: { label: 'Hide Catchlight', keys: { mac: 'Mod+H' }, role: 'hide', only: ['mac'] },
  hideOthers: { label: 'Hide Others', keys: { mac: 'Mod+Alt+H' }, role: 'hideOthers', only: ['mac'] },
  showAll: { label: 'Show All', role: 'unhide', only: ['mac'] },
  services: { label: 'Services', role: 'services', only: ['mac'] },
  quit: { label: PLAT === 'windows' ? 'Exit' : 'Quit Catchlight', keys: { mac: 'Mod+Q', windows: 'Alt+F4', linux: 'Mod+Q' }, role: 'quit' },
  help: { label: 'Catchlight Help', run: () => window.open(supportUrl, '_blank', 'noopener') },
  report: { label: 'Report an Issue…', run: () => window.open(reportUrl(), '_blank', 'noopener') },
  copyInfo: { label: 'Copy Version and Device Info', run: () => shell.copyText(supportInfo()) },
};

// The bar itself. The Mac keeps About, Settings and Quit in the app menu, and has Window; Windows
// and Linux put Settings and Exit/Quit under File and About under Help, as their own apps do.
const MENUS = [
  { title: 'Catchlight', only: ['mac'], items: ['about', SEP, 'settings', SEP, 'services', SEP, 'hide', 'hideOthers', 'showAll', SEP, 'quit'] },
  { title: 'File', items: ['newTake', 'newScript', SEP, 'exportTakes', 'importFile', 'importNotes', SEP, 'syncNow',
    ...(PLAT === 'mac' ? [SEP, 'closeWindow'] : [SEP, 'settings', SEP, 'quit'])] },
  { title: 'Edit', items: ['undo', 'redo', SEP, 'cut', 'copy', 'paste', 'pasteMatch', 'selectAll', SEP, 'find', ...(PLAT === 'mac' ? [SEP, 'emoji'] : [])] },
  { title: 'Take', items: ['doneEditing', SEP, 'markDone', 'important', 'obie', 'reminder', 'shotList', SEP, 'exportTake', SEP, 'deleteTake'] },
  { title: 'Format', items: ['bold', 'italic', 'strike', 'code', SEP, 'body', 'h1', 'h2', 'h3', SEP, 'checklist', 'bullets', 'numbers', 'quote', SEP, 'table', 'addRow', 'addColumn', 'removeColumn'] },
  { title: 'View', items: ['dailies', 'storyboard', 'sequence', SEP, 'paneDailies', 'paneScripts', SEP,
    { title: 'Scene', items: ['sceneAuto', 'sceneNight', 'sceneDaylight'] }, { title: 'Page', items: ['pageContinuous', 'pageA4', 'pageLetter'] }, SEP, 'fullScreen'] },
  { title: 'Window', only: ['mac'], items: ['minimize', 'zoom', SEP, 'front'] },
  { title: 'Help', items: ['help', 'report', 'copyInfo', ...(PLAT === 'mac' ? [] : [SEP, 'about'])] },
];

// ---------- keys ----------
const keyOf = (item, plat = PLAT) => item.keys?.[plat] ?? item.keys?.all ?? null;
const GLYPH = { Ctrl: '⌃', Alt: '⌥', Shift: '⇧', Mod: '⌘' };
const NAMES = { Backspace: '⌫', Right: '→', Left: '←', Up: '↑', Down: '↓', Space: 'Space', ',': ',' };
function keyLabel(k, plat = PLAT) {
  if (!k) return '';
  const parts = k.split('+'), key = parts.pop();
  if (plat === 'mac') return ['Ctrl', 'Alt', 'Shift', 'Mod'].filter(m => parts.includes(m)).map(m => GLYPH[m]).join('') + (NAMES[key] || key);
  return [...parts.map(m => m === 'Mod' ? 'Ctrl' : m), { Backspace: 'Backspace', Right: 'Right', Left: 'Left', Delete: 'Del' }[key] || key].join('+');
}
// The KeyboardEvent.code a key name means, so Shift+7 matches whatever the layout types.
// Letters match the character typed (e.key), so ⌘C is Copy on Dvorak too; digits and named keys
// match the physical key (e.code), so ⇧⌘7 works whatever Shift+7 types on the layout.
const CODE = k => /^[0-9]$/.test(k) ? 'Digit' + k
  : { ',': 'Comma', Backspace: 'Backspace', Right: 'ArrowRight', Left: 'ArrowLeft', Up: 'ArrowUp', Down: 'ArrowDown', Space: 'Space', Delete: 'Delete' }[k] || k;
function keyMatches(k, e) {
  const parts = k.split('+'), key = parts.pop(), mac = PLAT === 'mac';
  const want = { meta: mac && parts.includes('Mod'), ctrl: mac ? parts.includes('Ctrl') : parts.includes('Mod'), alt: parts.includes('Alt'), shift: parts.includes('Shift') };
  return e.metaKey === want.meta && e.ctrlKey === want.ctrl && e.altKey === want.alt && e.shiftKey === want.shift
    && (/^[A-Z]$/.test(key) ? e.key.toLowerCase() === key.toLowerCase() : e.code === CODE(key));
}
// Two items on one key, on any desktop, is a bug: the second would never run.
function menuCollisions() {
  const out = [];
  for (const plat of ['mac', 'windows', 'linux']) {
    const seen = {};
    for (const [id, item] of Object.entries(ITEMS)) {
      if (item.only && !item.only.includes(plat)) continue;
      const k = keyOf(item, plat);
      if (!k) continue;
      if (seen[k]) out.push(`${plat}: ${k} is both ${seen[k]} and ${id}`); else seen[k] = id;
    }
  }
  return out;
}

// ---------- the bridge the shells call ----------
const val = v => typeof v === 'function' ? v() : v;
function itemModel(id) {
  const it = ITEMS[id];
  return { id, label: val(it.label), shortcut: keyOf(it), shortcutLabel: keyLabel(keyOf(it)), role: it.role || null,
    enabled: it.role ? true : (it.enabled ? !!it.enabled() : true), checked: it.checked ? !!it.checked() : null };
}
function menuModel(entries = MENUS) {
  return entries.filter(m => m === SEP || typeof m === 'string' ? !(ITEMS[m]?.only) || ITEMS[m].only.includes(PLAT) : !m.only || m.only.includes(PLAT))
    .map(m => m === SEP ? { separator: true } : typeof m === 'string' ? itemModel(m) : { title: m.title, items: menuModel(m.items) });
}
function runCommand(id) {
  const it = ITEMS[id];
  if (!it || it.role || (it.enabled && !it.enabled())) return false;
  it.run();
  return true;
}
window.catchlightMenu = { platform: PLAT, model: menuModel, run: runCommand, collisions: menuCollisions };

// In a browser, the shortcuts are this file's to bind. An item whose key a focused control already
// handles in place (undo in the Script editor, a table's columns) is left to that control; so is
// any key a handler earlier in the chain has claimed.
// A shell's native menu owns the keys there, so this binds only in a plain browser.
const inShell = !!(window.webkit?.messageHandlers?.catchlight || window.chrome?.webview || window.catchlightShell);
if (!inShell) document.addEventListener('keydown', e => {
  if (e.defaultPrevented || e.isComposing) return;
  for (const [id, it] of Object.entries(ITEMS)) {
    if (it.role || it.inPlace || (it.only && !it.only.includes(PLAT))) continue;
    const k = keyOf(it);
    if (!k || !keyMatches(k, e)) continue;
    if (it.enabled && !it.enabled()) return;
    e.preventDefault();
    it.run();
    return;
  }
});

// ---------- ?menu: a stand-in bar, to look at the menus before a shell exists ----------
if (new URLSearchParams(location.search).has('menu')) {
  const bar = document.createElement('nav');
  bar.className = 'menu-bar'; bar.setAttribute('aria-label', 'Menu bar (preview)');
  document.body.prepend(bar); document.body.classList.add('with-menu-bar');
  const list = entries => `<ul class="menu-list" role="menu">${entries.map(m => m.separator ? '<li class="menu-sep" role="separator"></li>'
    : m.items ? `<li class="menu-sub" role="none"><span role="menuitem" aria-haspopup="true">${esc(m.title)}</span>${list(m.items)}</li>`
    : `<li role="none"><button type="button" role="${m.checked === null ? 'menuitem' : 'menuitemcheckbox'}" data-cmd="${m.id}"${m.enabled ? '' : ' disabled'}${m.checked ? ' aria-checked="true"' : ''}${m.role ? ' data-role="1"' : ''}>`
      + `<span class="menu-check">${m.checked ? '✓' : ''}</span><span class="menu-label">${esc(m.label)}</span><span class="menu-key">${esc(m.shortcutLabel)}</span></button></li>`).join('')}</ul>`;
  let openAt = -1;
  const paintMenuBar = () => {
    bar.innerHTML = menuModel().map((m, i) => `<div class="menu${i === openAt ? ' open' : ''}"><button type="button" class="menu-title" data-menu="${i}" aria-expanded="${i === openAt}">${esc(m.title)}</button>${i === openAt ? list(m.items) : ''}</div>`).join('');
  };
  paintMenuBar();
  bar.addEventListener('mousedown', e => {
    e.preventDefault();   // keep focus where it is, so a command acts on the Take or block in hand
    e.stopPropagation();  // the repaint below detaches the target, so the outside-press check can't see it was ours
    const t = e.target.closest('[data-menu]'), c = e.target.closest('[data-cmd]');
    if (t) { openAt = openAt === +t.dataset.menu ? -1 : +t.dataset.menu; paintMenuBar(); }
    else if (c && !c.disabled) { openAt = -1; paintMenuBar(); if (!c.dataset.role) runCommand(c.dataset.cmd); }
  });
  bar.addEventListener('mouseover', e => { const t = e.target.closest('[data-menu]'); if (t && openAt >= 0 && +t.dataset.menu !== openAt) { openAt = +t.dataset.menu; paintMenuBar(); } });
  document.addEventListener('mousedown', e => { if (openAt >= 0 && !bar.contains(e.target)) { openAt = -1; paintMenuBar(); } });
  document.addEventListener('keydown', e => { if (e.key === 'Escape' && openAt >= 0) { openAt = -1; paintMenuBar(); } }, true);
}

const clash = menuCollisions();
if (clash.length) console.error('Menu shortcut collisions:\n' + clash.join('\n'));
