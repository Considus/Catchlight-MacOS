'use strict';
// Dailies: Takes, in-place editing and the Focus-ring, as the iOS app does them (As-Built,
// D-274). Loaded after app.js and uses its helpers. The model mirrors CatchlightCore's
// Take: ordered blocks of text and checklist items; a Take is a Task when it has a
// checklist item and complete when every item is ticked. Placeholder data, no sync.

const DAY = 864e5;
const at = (days, h, m) => { const d = new Date(); d.setHours(h, m, 0, 0); return new Date(d.getTime() + days * DAY).toISOString(); };

let takes = store.get('takes2', [
  { id: 't1', at: '2026-06-28T09:00:00Z', blocks: [{ k: 'text', text: 'Call the framer about the exhibition print' }], isNote: false, isImportant: true, obie: true, reminder: { when: at(1, 9, 0), done: false } },
  { id: 't2', at: '2026-06-29T10:00:00Z', blocks: [{ k: 'text', text: 'The eye is the lamp of the body. Might belong on the About page one day.' }], isNote: true },
  { id: 't3', at: '2026-06-30T08:00:00Z', blocks: [{ k: 'text', text: 'Water the studio plants' }], isNote: false, reminder: { when: at(-1, 18, 30), done: false } },
  { id: 't4', at: '2026-06-30T12:00:00Z', blocks: [{ k: 'check', text: 'Send the June invoice', done: true }, { k: 'check', text: 'Back up the Whitby shoot', done: true }], isNote: false },
  { id: 't5', at: '2026-07-02T07:30:00Z', blocks: [{ k: 'text', text: 'Winter series idea. Cold light, long shadows, one subject, no colour.' }], isNote: true },
  { id: 't6', at: '2026-07-04T16:00:00Z', blocks: [{ k: 'text', text: 'Before the weekend' }, { k: 'check', text: 'Ask Sam about the second-hand 90mm lens', done: false }, { k: 'check', text: 'Lens cloth', done: false }], isNote: true },
  { id: 't7', at: '2026-07-09T11:00:00Z', blocks: [{ k: 'text', text: 'Paper stock: Hahnemühle Photo Rag 308 for the large prints, Baryta for the small ones.' }], isNote: true, isImportant: true },
]);
const saveTakes = () => store.set('takes2', takes);

// ---------- what a Take is (CatchlightCore's derived properties) ----------
const isTask = t => t.blocks.some(b => b.k === 'check');
const isComplete = t => isTask(t) && t.blocks.filter(b => b.k === 'check').every(b => b.done);
const canBeMarkedDone = t => isTask(t) || !!t.reminder;
const isDone = t => (isTask(t) ? isComplete(t) : true) && (t.reminder ? t.reminder.done : true) && canBeMarkedDone(t);
const isOverdue = t => !!t.reminder && !t.reminder.done && new Date(t.reminder.when) < new Date();
const typesOf = t => [t.isNote && 'note', isTask(t) && 'task', t.reminder && 'remind', t.isImportant && 'important'].filter(Boolean);
const textOf = t => t.blocks.map(b => b.k === 'check' ? `- [${b.done ? 'x' : ' '}] ${b.text}` : b.text).join('\n');
const isBlank = t => !t.blocks.some(b => b.text.trim()) && !isTask(t) && !t.reminder;
// A Take is never "none": with no Task, no reminder and no Note, Note comes back on.
const noteFloor = t => { if (!t.isNote && !isTask(t) && !t.reminder) t.isNote = true; };
const irisHtml = (types, obie) => `<span class="iris-shadow"></span>${iris(types, obie)}`;

// "Tomorrow at 09:00", as the iOS reminder line reads, in the viewer's own locale.
function whenLabel(iso) {
  const d = new Date(iso), today = new Date(); today.setHours(0, 0, 0, 0);
  const day = Math.round((new Date(d).setHours(0, 0, 0, 0) - today) / DAY);
  const time = d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  const name = { '-1': 'Yesterday', 0: 'Today', 1: 'Tomorrow' }[day]
    ?? d.toLocaleDateString([], { weekday: 'short', day: 'numeric', month: 'short' });
  return `${name} at ${time}`;
}

// ---------- the timeline card ----------
function takeCard(t) {
  const cls = ['card', t.obie && 'obie', isOverdue(t) && 'overdue', isDone(t) && 'done'].filter(Boolean).join(' ');
  const body = t.blocks.map(b => `<span class="${b.k === 'check' && b.done ? 'ticked' : ''}">${esc(b.text)}</span>`).join('\n');
  let meta = '';
  if (isTask(t)) {
    const checks = t.blocks.filter(b => b.k === 'check');
    meta += `<div class="meta">${checks.filter(b => b.done).length} of ${checks.length} completed</div>`;
  }
  if (t.reminder) meta += `<div class="meta">${ICON_CLOCK}${ICON_BELL}${esc(whenLabel(t.reminder.when))}</div>`;
  return `<div class="${cls}" data-take="${t.id}"><span class="iris-wrap" data-iris="${t.id}">${irisHtml(typesOf(t), t.obie)}</span><div class="body">${body}</div>${meta}</div>`;
}

function renderTakes() {
  // The Obie is pinned above the timeline and never scrolls, as on iOS.
  const obie = takes.find(t => t.obie);
  const pinned = $('#pinned');
  pinned.hidden = !obie;
  pinned.innerHTML = obie ? takeCard(obie) : '';
  $('#takes').classList.toggle('under-obie', !!obie);
  // Oldest first, as on iOS; the view options belong to the Scripts list.
  timeline($('#takes'), takes.filter(t => t !== obie).sort((a, b) => a.at.localeCompare(b.at)), takeCard);
}

// ---------- in-place editing ----------
// The edited Take floats above the editor bar and grows upward, the list dimmed behind it
// (KeyboardTakeEditor on iOS). Clicking outside, Escape and ⌘S save; only × discards.
const sidebar = $('#sidebar'), editorCard = $('#take-editor'), rows = $('#take-rows');
let draft = null, original = null, focusRing = null;

function beginEdit(t, isNew = false) {
  if (draft) commitEdit();
  original = isNew ? null : t;
  draft = structuredClone(t);
  if (!draft.blocks.length) draft.blocks.push({ k: 'text', text: '' });
  sidebar.classList.add('editing');
  editorCard.hidden = false;
  paintEditor();
  focusRow(rows.children.length - 1, Infinity);
}

function paintEditor() {
  editorCard.classList.toggle('obie', !!draft.obie);
  paintIris();
  rows.innerHTML = '';
  draft.blocks.forEach(b => rows.append(rowFor(b)));
  paintBar();
}

function rowFor(b) {
  const row = document.createElement('div');
  row.className = 'erow ' + b.k + (b.done ? ' ticked' : '');
  if (b.k === 'check') {
    const box = document.createElement('button');
    box.className = 'echeck'; box.type = 'button';
    box.setAttribute('aria-label', b.done ? 'Not done' : 'Done');
    box.setAttribute('aria-pressed', String(!!b.done));
    row.append(box);
  }
  const text = document.createElement('div');
  text.className = 'etext';
  try { text.contentEditable = 'plaintext-only'; } catch { text.contentEditable = 'true'; }
  text.textContent = b.text;
  row.append(text);
  if (b.k === 'check') { const h = document.createElement('span'); h.className = 'ehandle'; h.setAttribute('aria-hidden', 'true'); row.append(h); }
  return row;
}

function readRows() {
  draft.blocks = [...rows.children].map(r => {
    const text = r.querySelector('.etext').textContent;
    return r.classList.contains('check') ? { k: 'check', text, done: r.classList.contains('ticked') } : { k: 'text', text };
  });
}

function focusRow(i, offset) {
  const el = rows.children[i]?.querySelector('.etext');
  if (!el) return;
  el.focus();
  setCaret(el, Math.min(offset, el.textContent.length));
}

function commitEdit() {
  if (!draft) return;
  readRows();
  // removeEmptyTextBlocks, then the blank rule: a blank Take is never kept (AppModel).
  draft.blocks = draft.blocks.filter(b => b.k === 'check' || b.text.trim());
  if (isBlank(draft)) {
    if (original) takes = takes.filter(t => t.id !== original.id);
  } else {
    // D-250: an edit that changes nothing writes nothing, so modifiedAt only moves on a change.
    const same = original && JSON.stringify({ ...original, modifiedAt: 0 }) === JSON.stringify({ ...draft, modifiedAt: 0 });
    if (!same) {
      draft.modifiedAt = Date.now();
      if (draft.obie) takes.forEach(t => { if (t.id !== draft.id) t.obie = false; });
      takes = original ? takes.map(t => t.id === draft.id ? draft : t) : [...takes, draft];
    }
  }
  endEdit();
}

function discardEdit() { endEdit(); }

function endEdit() {
  closeReminder();   // the picker belongs to the edit; it never outlives it
  draft = original = null;
  editorCard.hidden = true;
  rows.innerHTML = '';   // nothing of an edit outlives it, discarded or not
  sidebar.classList.remove('editing');
  saveTakes(); renderTakes();
}

// Keys inside the editor, as BlockEditor.swift handles them.
rows.addEventListener('keydown', e => {
  const row = e.target.closest('.erow');
  if (!row) return;
  const i = [...rows.children].indexOf(row), text = row.querySelector('.etext');
  if (e.key === 'Enter' && !e.shiftKey && row.classList.contains('check')) {
    e.preventDefault();
    readRows();
    if (!text.textContent.trim()) {
      draft.blocks[i] = { k: 'text', text: '' };                       // an empty item leaves the list
    } else {
      draft.blocks.splice(i + 1, 0, { k: 'check', text: '', done: false });
    }
    paintEditor();
    focusRow(text.textContent.trim() ? i + 1 : i, 0);
  } else if (e.key === 'Backspace' && !text.textContent && getSelection().isCollapsed) {
    e.preventDefault();
    readRows();
    if (i === 0 && row.classList.contains('check')) draft.blocks[0] = { k: 'text', text: '' };
    else draft.blocks.splice(i, 1);
    if (!draft.blocks.length) draft.blocks.push({ k: 'text', text: '' });
    paintEditor();
    focusRow(Math.max(0, i - (i === 0 ? 0 : 1)), Infinity);
  }
});
rows.addEventListener('click', e => {
  const box = e.target.closest('.echeck');
  if (!box) return;
  box.closest('.erow').classList.toggle('ticked');
  readRows(); paintBar();
  draft.blocks.length && paintIris();
});
rows.addEventListener('input', () => { readRows(); paintIris(); paintBar(); });
function paintIris() { $('#take-editor-iris').innerHTML = irisHtml(typesOf(draft), draft.obie); }

// Save on any press outside the card and its bar; Escape and ⌘S save too.
document.addEventListener('mousedown', e => {
  swallowClick = false;   // a press with no click after it must not leave the flag set
  if (!draft || focusRing) return;
  if (e.target.closest('#take-editor, #editor-bar, #reminder-pop')) return;
  if (sidebar.contains(e.target)) { e.preventDefault(); swallowClick = true; }
  commitEdit();
}, true);
document.addEventListener('keydown', e => {
  if (!draft || focusRing || reminderFor) return;
  if (e.key === 'Escape' || ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 's')) {
    e.preventDefault();
    commitEdit();
  }
});

// ---------- the editor bar (EditorKeyboardBar on iOS) ----------
function paintBar() {
  const task = isTask(draft);
  $('#eb-third').innerHTML = task ? ICON_CHECKLIST : ICON_IMPORTANT;
  $('#eb-third').setAttribute('aria-label', task ? 'Shot List (not built yet)' : (draft.isImportant ? 'Remove Important' : 'Make Important'));
  $('#eb-done').disabled = !canBeMarkedDone(draft);
}
$('#eb-discard').addEventListener('click', discardEdit);
$('#eb-third').addEventListener('click', () => {
  readRows();
  if (isTask(draft)) return;                                            // the Shot List Angle is not built yet
  draft.isImportant = !draft.isImportant;
  if (!draft.isImportant) noteFloor(draft);
  paintIris(); paintBar();
});
$('#eb-done').addEventListener('click', () => {
  readRows();
  toggleDone(draft);
  paintEditor();
});
$('#eb-remind').addEventListener('click', () => { readRows(); openReminder(draft, () => { paintIris(); paintBar(); }); });

// Mark done for the whole Take: every item ticked and the reminder done, or all undone.
function toggleDone(t) {
  const done = !isDone(t);
  t.blocks.forEach(b => { if (b.k === 'check') b.done = done; });
  if (t.reminder) t.reminder.done = done;
}

// ---------- reminder picker (a plain date-and-time field for this cut) ----------
let reminderFor = null, reminderAfter = null;
function openReminder(t, after, onCancel) {
  reminderFor = t; reminderAfter = after;
  const d = t.reminder ? new Date(t.reminder.when) : (() => { const n = new Date(Date.now() + DAY); n.setHours(9, 0, 0, 0); return n; })();
  const local = new Date(d.getTime() - d.getTimezoneOffset() * 6e4).toISOString().slice(0, 16);
  $('#reminder-when').value = local;
  $('#reminder-remove').hidden = !t.reminder;
  $('#reminder-pop').hidden = false;
  reminderCancel = onCancel || null;
}
let reminderCancel = null;
function closeReminder() { $('#reminder-pop').hidden = true; reminderFor = reminderAfter = reminderCancel = null; }
$('#reminder-save').addEventListener('click', () => {
  const v = $('#reminder-when').value;
  if (v) reminderFor.reminder = { when: new Date(v).toISOString(), done: false };
  const after = reminderAfter; closeReminder(); after && after();
});
$('#reminder-remove').addEventListener('click', () => {
  reminderFor.reminder = null;
  noteFloor(reminderFor);
  const after = reminderAfter; closeReminder(); after && after();
});
const cancelReminder = () => { const c = reminderCancel; closeReminder(); c && c(); };
$('#reminder-cancel').addEventListener('click', cancelReminder);
// Escape with the picker open closes the picker only, not the ring or the edit beneath it.
document.addEventListener('keydown', e => { if (reminderFor && e.key === 'Escape') { e.preventDefault(); e.stopImmediatePropagation(); cancelReminder(); } });

// ---------- the Focus-ring (FocusRingFanView on iOS) ----------
// Four Marks fan out to the right of the Iris at R = 68: Note -80°, Task -26.7°,
// Remind +26.7°, Important +80°. A Take is never "none": with Task and Remind both off,
// Note comes back on. Clicking the veil applies the selection and closes.
const MARKS = [
  { key: 'note', deg: -80, label: 'Note', icon: '<svg viewBox="0 0 24 24"><rect x="5" y="4" width="14" height="16" rx="2"/><path d="M8.5 9h7M8.5 12.5h7M8.5 16h4"/></svg>' },
  { key: 'task', deg: -26.67, label: 'Task', icon: '<svg viewBox="0 0 24 24"><rect x="4.5" y="4.5" width="15" height="15" rx="3"/><path d="M8.5 12.2l2.6 2.6 4.6-5.3"/></svg>' },
  { key: 'remind', deg: 26.67, label: 'Remind', icon: '<svg viewBox="0 0 24 24"><path d="M6 16V11a6 6 0 0 1 12 0v5l1.5 2h-15zM10 20.5h4"/></svg>' },
  { key: 'important', deg: 80, label: 'Important', icon: '<span class="bang">!</span>' },
];

function openFocusRing(t, irisEl, fromEditor) {
  if (focusRing) return;
  closeReminder();   // a picker opened from the editor bar does not carry into the ring
  if (fromEditor) readRows();
  const box = irisEl.getBoundingClientRect(), host = sidebar.getBoundingClientRect();
  const cx = box.left + box.width / 2 - host.left, cy = box.top + box.height / 2 - host.top;
  const sel = new Set(typesOf(t).filter(k => k !== 'image' && k !== 'voice'));
  const ring = $('#focus-ring');
  ring.innerHTML = '';
  ring.style.setProperty('--cx', cx + 'px'); ring.style.setProperty('--cy', cy + 'px');
  // From the timeline, the tapped card is lifted above the veil, lit.
  if (!fromEditor) {
    const card = irisEl.closest('.card'), r = card.getBoundingClientRect();
    const lift = card.cloneNode(true);
    lift.classList.add('lifted');
    Object.assign(lift.style, { left: r.left - host.left + 'px', top: r.top - host.top + 'px', width: r.width + 'px', margin: 0 });
    lift.querySelector('.iris-wrap')?.remove();
    ring.append(lift);
  }
  const hub = document.createElement('div');
  hub.className = 'hub';
  hub.innerHTML = irisHtml([...sel], t.obie) + '<i class="tick"></i>';
  ring.append(hub);
  for (const m of MARKS) {
    const b = document.createElement('button');
    b.className = 'mark' + (sel.has(m.key) ? ' on' : '');
    b.dataset.key = m.key; b.type = 'button';
    b.setAttribute('aria-label', m.label); b.setAttribute('aria-pressed', String(sel.has(m.key)));
    const rad = m.deg * Math.PI / 180;
    b.style.setProperty('--dx', (68 * Math.cos(rad)).toFixed(1) + 'px');
    b.style.setProperty('--dy', (68 * Math.sin(rad)).toFixed(1) + 'px');
    b.innerHTML = m.icon;
    ring.append(b);
  }
  focusRing = { t, sel, fromEditor };
  ring.hidden = false;
  sidebar.classList.add('ringed');
  requestAnimationFrame(() => requestAnimationFrame(() => ring.classList.add('open')));
}

function paintRing() {
  const { t, sel } = focusRing;
  document.querySelectorAll('#focus-ring .mark').forEach(b => {
    b.classList.toggle('on', sel.has(b.dataset.key));
    b.setAttribute('aria-pressed', String(sel.has(b.dataset.key)));
  });
  $('#focus-ring .hub').innerHTML = irisHtml([...sel], t.obie) + '<i class="tick"></i>';
}

$('#focus-ring').addEventListener('click', e => {
  if (!focusRing) return;
  const mark = e.target.closest('.mark');
  if (!mark) { closeFocusRing(true); return; }
  const { sel, t } = focusRing, k = mark.dataset.key;
  if (sel.has(k)) sel.delete(k); else sel.add(k);
  if (!sel.has('task') && !sel.has('remind')) sel.add('note');          // never "none"
  if (k === 'remind' && sel.has('remind') && !t.reminder) {
    // Turning Remind on asks when; cancelling turns it back off.
    const target = { ...t, reminder: null, isNote: t.isNote };
    openReminder(target, () => { focusRing.pendingReminder = target.reminder; paintRing(); },
      () => { sel.delete('remind'); if (!sel.has('task')) sel.add('note'); paintRing(); });
  }
  paintRing();
});

function closeFocusRing(apply) {
  const { t, sel, fromEditor, pendingReminder } = focusRing;
  if (reminderFor) {   // closing the ring cancels a picker it opened, which turns Remind back off
    sel.delete('remind'); if (!sel.has('task')) sel.add('note');
    closeReminder();
  }
  if (apply) {
    const target = fromEditor ? draft : takes.find(x => x.id === t.id);
    const before = JSON.stringify(target);
    // Only what changed is written, so an unchanged ring is a no-op (D-250).
    if (!!target.isNote !== sel.has('note')) target.isNote = sel.has('note');
    if (!!target.isImportant !== sel.has('important')) target.isImportant = sel.has('important');
    if (sel.has('task') && !isTask(target)) target.blocks.push({ k: 'check', text: '', done: false });
    if (!sel.has('task') && isTask(target)) target.blocks = target.blocks.map(b => ({ k: 'text', text: b.text }));
    if (!sel.has('remind')) { if (target.reminder) target.reminder = null; }   // a picked time with Remind off is dropped
    else if (pendingReminder) target.reminder = pendingReminder;
    if (!fromEditor && JSON.stringify(target) !== before) { target.modifiedAt = Date.now(); saveTakes(); }
  }
  const ring = $('#focus-ring');
  ring.classList.remove('open');
  focusRing = null;
  setTimeout(() => { ring.hidden = true; ring.innerHTML = ''; sidebar.classList.remove('ringed'); }, still.matches ? 0 : 840);
  if (fromEditor) { paintEditor(); focusRow(rows.children.length - 1, Infinity); }
  else {
    renderTakes();
    // Turning Task on from the timeline opens the editor on the new empty item, as on iOS.
    const target = takes.find(x => x.id === t.id);
    if (apply && sel.has('task') && target && target.blocks.at(-1)?.k === 'check' && !target.blocks.at(-1).text) beginEdit(target);
  }
}
document.addEventListener('keydown', e => { if (focusRing && !reminderFor && e.key === 'Escape') { e.preventDefault(); closeFocusRing(true); } });

// ---------- clicks and presses on the timeline ----------
// Click a card's body to edit it; click its Iris for the Focus-ring; hold the Iris for
// 0.45s to make it the Obie (or stop it being one).
let irisHold = null;
sidebar.addEventListener('pointerdown', e => {
  const ir = e.target.closest('.timeline .iris-wrap, #pinned .iris-wrap');
  if (!ir || draft) return;
  const hold = irisHold = { id: ir.dataset.iris, x: e.clientX, y: e.clientY, fired: false, t: setTimeout(() => {
    hold.fired = true;
    const t = takes.find(x => x.id === hold.id);
    const make = !t.obie;
    takes.forEach(x => { x.obie = false; });
    t.obie = make; if (make) t.isImportant = true;   // becoming the Obie makes it Important; Important can be removed later, as on iOS (Take.isObie)
    t.modifiedAt = Date.now(); saveTakes(); renderTakes();
  }, 450) };
});
// A hold that moves (a scroll) or is cancelled is not a hold.
const dropHold = () => { if (irisHold && !irisHold.fired) { clearTimeout(irisHold.t); irisHold = null; } };
document.addEventListener('pointermove', e => { if (irisHold && Math.hypot(e.clientX - irisHold.x, e.clientY - irisHold.y) > 10) dropHold(); });
document.addEventListener('pointerup', () => { if (irisHold && !irisHold.fired) clearTimeout(irisHold.t); });
document.addEventListener('pointercancel', dropHold);
sidebar.addEventListener('click', e => {
  if (draft || focusRing) return;
  const ir = e.target.closest('.timeline .iris-wrap, #pinned .iris-wrap');
  if (ir) {
    if (irisHold?.fired) { irisHold = null; return; }
    irisHold = null;
    openFocusRing(takes.find(x => x.id === ir.dataset.iris), ir, false);
    return;
  }
  const card = e.target.closest('.timeline .card, #pinned .card');
  if (card) beginEdit(takes.find(x => x.id === card.dataset.take));
});
$('#take-editor-iris').addEventListener('click', () => openFocusRing(draft, $('#take-editor-iris'), true));
$('#add-take').addEventListener('click', () => {
  beginEdit({ id: 't' + Date.now(), at: new Date().toISOString(), blocks: [{ k: 'text', text: '' }], isNote: true }, true);
});

// ---------- the Take menu (right-click, or long press on touch) ----------
// The iOS long-press menu, less Expand and Export, plus Expand into a Script (D-313).
function takeMenu(id) {
  const t = takes.find(x => x.id === id);
  const items = [];
  if (canBeMarkedDone(t)) items.push([isDone(t) ? 'Mark Not Done' : 'Mark Done', () => { toggleDone(t); touch(t); }]);
  items.push([t.isImportant ? 'Remove Important' : 'Make Important', () => {
    t.isImportant = !t.isImportant;
    if (!t.isImportant) noteFloor(t);
    touch(t);
  }]);
  if (!t.obie) items.push(['Make Obie', () => { takes.forEach(x => { x.obie = false; }); t.obie = true; t.isImportant = true; touch(t); }]);
  items.push(['Expand into a Script', () => {
    takes = takes.filter(x => x !== t);
    saveTakes(); renderTakes(); newScript(linesToBlocks(textOf(t)));
  }]);
  items.push(['Delete Take', null, 'danger']);
  return items;
}
function touch(t) { t.modifiedAt = Date.now(); saveTakes(); renderTakes(); }
function deleteTake(id) { takes = takes.filter(x => x.id !== id); saveTakes(); renderTakes(); }

// A Script made back into a Take: "- [ ]" lines become checklist items, the rest text.
function takeFromScript(s) {
  const blocks = [];
  for (const line of s.blocks.join('\n').split('\n')) {
    const m = line.match(/^[-*] \[( |x|X)\] (.*)$/);
    if (m) blocks.push({ k: 'check', text: m[2], done: m[1] !== ' ' });
    else if (blocks.at(-1)?.k === 'text') blocks.at(-1).text += '\n' + line;
    else blocks.push({ k: 'text', text: line });
  }
  // removeEmptyTextBlocks, as a save does; a Script that leaves a blank Take is not offered.
  return { id: 't' + Date.now(), at: s.at + (s.at.length === 10 ? 'T00:00:00Z' : ''), blocks: blocks.filter(b => b.k === 'check' || b.text.trim()), isNote: true };
}

// A press outside the edited Take saves it and does nothing else inside Dailies, as a tap
// does on iOS: the click that follows is swallowed there. Elsewhere it goes through.
let swallowClick = false;   // set by the saving mousedown above
document.addEventListener('click', e => { if (swallowClick) { swallowClick = false; e.stopPropagation(); e.preventDefault(); } }, true);

renderTakes();
