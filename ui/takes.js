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
// An Obie is always Important (Take.isObie's didSet, and the decoder ORs it back in on load).
takes.forEach(t => { if (t.obie) t.isImportant = true; });
const saveTakes = () => store.set('takes2', takes);

// ---------- what a Take is (CatchlightCore's derived properties) ----------
const isTask = t => t.blocks.some(b => b.k === 'check');
const isComplete = t => isTask(t) && t.blocks.filter(b => b.k === 'check').every(b => b.done);
const canBeMarkedDone = t => isTask(t) || !!t.reminder;
// A repeating reminder is never done (TimeReminder): Done moves it on to its next occurrence.
const isDone = t => (isTask(t) ? isComplete(t) : true) && (t.reminder ? !repeats(t.reminder) && t.reminder.done : true) && canBeMarkedDone(t);
// Overdue: a one-off time reminder not done and past. A place, or a repeat, never is.
const isOverdue = t => isTimeR(t.reminder) && !repeats(t.reminder) && !t.reminder.done && new Date(t.reminder.when) < new Date();
const typesOf = t => [t.isNote && 'note', isTask(t) && 'task', t.reminder && 'remind', t.isImportant && 'important'].filter(Boolean);
const textOf = t => t.blocks.map(b => b.k === 'check' ? `- [${b.done ? 'x' : ' '}] ${b.text}` : b.text).join('\n');
const isBlank = t => !t.blocks.some(b => b.text.trim()) && !isTask(t) && !t.reminder;
// A Take is never "none": with no Task, no reminder and no Note, Note comes back on.
const noteFloor = t => { if (!t.isNote && !isTask(t) && !t.reminder) t.isNote = true; };
const irisHtml = (types, obie) => `<span class="iris-shadow"></span>${iris(types, obie)}`;


// ---------- manual arrangement (ManualOrder.swift, D-195) ----------
// `manualOrder` is a sparse fractional index. A Take never dragged has none and sits at its
// creation time in epoch seconds, so turning Manual on changes nothing until a card moves, and
// a new Take lands at the now end. The canonical order is oldest first; Order (oldest or
// newest) reverses what is shown, never the stored values.
const ORDER_STEP = 0.001;   // one millisecond, the resolution of every stored time
const effectiveOrder = t => t.manualOrder ?? Date.parse(t.at) / 1000;
const arranged = list => [...list].sort((a, b) => effectiveOrder(a) - effectiveOrder(b) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
// The values to store so `id` comes to rest at `destination` (an index into the canonical
// order without it). Normally one Take; nothing when it lands where it started; every Take,
// renumbered 1, 2, 3…, only when halving a gap has run out of precision.
function reorderValues(list, id, destination) {
  const canonical = arranged(list), from = canonical.findIndex(t => t.id === id);
  if (from < 0) return {};
  const others = canonical.filter(t => t.id !== id), index = Math.max(0, Math.min(destination, others.length));
  if (index === from) return {};
  const below = index > 0 ? effectiveOrder(others[index - 1]) : null;
  const above = index < others.length ? effectiveOrder(others[index]) : null;
  if (below === null && above === null) return {};
  if (below === null) return { [id]: above - ORDER_STEP };
  if (above === null) return { [id]: below + ORDER_STEP };
  const mid = below + (above - below) / 2;
  if (mid > below && mid < above) return { [id]: mid };
  const seq = [...others]; seq.splice(index, 0, canonical[from]);
  return Object.fromEntries(seq.map((t, i) => [t.id, i + 1]));
}
// Dragging is offered only on the whole timeline: never under a filter or a search, since a
// list with its middle hidden can't be honestly arranged.
const inOrder = canonical => settings.takeSort === 'newest' ? canonical.reverse() : canonical;
const canReorder = () => settings.takeArrangement === 'manual' && !storyboard && dock === 'resting' && !filterMonth;
// Write the new order. `displayIds` is the timeline as shown after the move.
function commitReorder(id, displayIds) {
  const canonical = settings.takeSort === 'newest' ? [...displayIds].reverse() : displayIds;
  const values = reorderValues(takes.filter(t => !t.obie), id, canonical.indexOf(id));
  const now = Date.now();
  for (const [tid, order] of Object.entries(values)) {
    const t = takes.find(x => x.id === tid);
    if (t && t.manualOrder !== order) { t.manualOrder = order; t.modifiedAt = now; }   // the sync pushes on modifiedAt
  }
  saveTakes(); renderTakes();
}

// ---------- the timeline card ----------
function takeCard(t) {
  // Links are live, as on the card on iOS; with two or more the lines open up so each is easy
  // to hit (TakeRowView.bodyNeedsLinkSpacing).
  const links = t.blocks.reduce((n, b) => n + detectLinks(b.text).length, 0);
  // Surface and border as TakeCardStyle on iOS: an Important Take sits on the Obie's surface;
  // the border shows state, and app.css orders the rules so the first that applies wins.
  const cls = ['card', t.isImportant && 'important', t.reminder && 'remind', isTask(t) && 'task', isDone(t) && 'done', t.obie && 'obie', isOverdue(t) && 'overdue', links >= 2 && 'links'].filter(Boolean).join(' ');
  const body = t.blocks.map(b => `<span class="${b.k === 'check' && b.done ? 'ticked' : ''}">${linkify(b.text)}</span>`).join('\n');
  let meta = '';
  if (isTask(t)) {
    const checks = t.blocks.filter(b => b.k === 'check');
    meta += `<div class="meta">${checks.filter(b => b.done).length} of ${checks.length} completed</div>`;
  }
  if (t.reminder) meta += reminderMeta(t.reminder);   // reminders.js
  if (settings.creationStamp === 'always') meta += `<div class="stamp">${esc(createdLabel(t.at))}</div>`;   // Settings → Creation date
  return `<div class="${cls}${expanded.has(t.id) ? ' expanded' : ''}" data-take="${t.id}" ${cardA11y(t)}><span class="iris-wrap" data-iris="${t.id}" ${irisA11y(t)}>${irisHtml(typesOf(t), t.obie)}</span><div class="body">${body}</div>${meta}${reorderHandle(t)}</div>`;
}
// The ≡ strip on the card's trailing edge in Manual (TimelineDragHandle). It is a button so the
// keyboard can reach it: ⌥↑ and ⌥↓ stand in for VoiceOver's Move up and Move down.
const reorderHandle = t => !t.obie && canReorder() ? `<button class="thandle" type="button" aria-label="Move ${esc(t.blocks.find(b => b.text.trim())?.text.slice(0, 40) || 'Take')}" title="Drag to move, or ⌥↑ ⌥↓"></button>` : '';

function renderTakes() {
  $('#dailies-heading').textContent = storyboard ? 'Storyboard' : { resting: 'Dailies', filtering: 'Sequence', searching: 'Search' }[dock];
  $('#sb-close').hidden = !storyboard;
  sidebar.classList.toggle('storyboard', storyboard);
  const list = $('#takes'), pinned = $('#pinned');
  for (const el of [list, pinned]) { el.dataset.preview = settings.takePreview; el.dataset.spacing = settings.takeSpacing; }
  const order = (a, b) => settings.takeSort === 'newest' ? b.at.localeCompare(a.at) : a.at.localeCompare(b.at);
  // The Storyboard is not the timeline: plain cards, no spine and no Iris (StoryboardView).
  list.classList.toggle('storyboard', storyboard);
  if (storyboard) {
    // Every Take with an unticked item, the Obie among them and not pinned; no month dividers.
    pinned.hidden = true; list.classList.remove('under-obie');
    // A hand-arranged timeline is honoured here too; the Storyboard has no drag of its own.
    const open = takes.filter(t => isTask(t) && !isComplete(t));
    const items = settings.takeArrangement === 'manual' ? inOrder(arranged(open)) : open.sort(order);
    list.innerHTML = items.length ? items.map(takeCard).join('')
      : '<div class="empty"><p class="empty-title">Nothing planned yet</p><p>Takes with a task appear here.</p></div>';
  } else {
    // The Obie is pinned above the timeline, never scrolls and is never filtered, as on iOS.
    const obie = takes.find(t => t.obie);
    pinned.hidden = !obie;
    pinned.innerHTML = obie ? takeCard(obie) : '';
    list.classList.toggle('under-obie', !!obie);
    // Order and Arrangement from Settings → Dailies. Manual hides the month rows and shows
    // the hand-made order, which the ≡ handle changes.
    const shown = takes.filter(t => t !== obie && matches(t));
    list.classList.toggle('reorderable', canReorder());
    // Nothing at all yet (not a filter that matches nothing): iOS's empty state.
    if (!takes.length) list.innerHTML = '<div class="empty first-take"><p>Your first Take is waiting.</p></div>';
    else if (settings.takeArrangement === 'manual') list.innerHTML = inOrder(arranged(shown)).map(takeCard).join('');
    else timeline(list, shown.sort(order), takeCard);
    const lit = filterMonth && list.querySelector(`.month[data-month="${filterMonth}"]`);
    if (lit) { lit.classList.add('on'); lit.querySelector('.month-label').insertAdjacentHTML('beforeend', ICON_XMARK); }
  }
  paintDock();
}

// ---------- in-place editing ----------
// The edited Take floats above the editor bar and grows upward, the list dimmed behind it
// (KeyboardTakeEditor on iOS). Clicking outside, Escape and ⌘S save; only × discards.
const sidebar = $('#sidebar'), editorCard = $('#take-editor'), rows = $('#take-rows');
let draft = null, original = null, focusRing = null;
let draftComplete = false;   // was every item ticked at the last change? (All tasks done)

function beginEdit(t, isNew = false) {
  if (draft) commitEdit();
  if (dock === 'searching') exitToResting();   // opening a Take leaves search first (UIState)
  original = isNew ? null : t;
  draft = structuredClone(t);
  draftComplete = isComplete(draft);
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
  $('#take-editor-stamp').textContent = settings.creationStamp !== 'off' ? createdLabel(draft.at) : '';
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
  refocus();   // a11y.js: back to the card the keyboard edited
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
  if (e.target.closest('#take-editor, #editor-bar, #reminder-sheet, #shot-list, dialog.alert')) return;
  if (sidebar.contains(e.target)) { e.preventDefault(); swallowClick = true; }
  commitEdit();
}, true);
document.addEventListener('keydown', e => {
  if (!draft || focusRing || reminderFor || alertBox.open || shotListOpen()) return;   // each closes itself
  if (e.key === 'Escape' || ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 's')) {
    e.preventDefault();
    commitEdit();
  }
});

// ---------- the editor bar (EditorKeyboardBar on iOS) ----------
function paintBar() {
  const task = isTask(draft);
  $('#eb-third').innerHTML = task ? ICON_CHECKLIST : ICON_IMPORTANT;
  $('#eb-third').setAttribute('aria-label', task ? 'Open Shot List' : (draft.isImportant ? 'Remove Important' : 'Make Important'));
  $('#eb-third').disabled = !task && !!draft.obie;   // an Obie stays Important
  $('#eb-done').disabled = !canBeMarkedDone(draft);
  const remind = draft.reminder ? 'Edit reminder' : 'Add reminder';   // EditorKeyboardBar's label
  $('#eb-remind').setAttribute('aria-label', remind); $('#eb-remind').title = remind;
  noteTicks();
}

// "All tasks done." (owner 2026-08-11): ticking the last item, in the editor or the Shot List,
// asks whether to stop the Take's reminder. Only in Dailies, only when the reminder would still
// fire: on, not done, and not one ReminderScheduler would skip anyway (a one-off on a Take that
// is nothing but a finished checklist). Stop removes the reminder; the Take stays.
function noteTicks() {
  const now = isComplete(draft), was = draftComplete;
  draftComplete = now;
  if (was || !now || storyboard) return;
  const r = draft.reminder;
  if (!isTimeR(r) || r.notify === false || r.done) return;
  if (!repeats(r) && draft.blocks.every(b => b.k === 'check')) return;
  ask('All tasks done.', 'Every task on this Take is ticked. Stop its reminder?', [
    ['Stop', () => { if (!draft) return; delete draft.reminder; noteFloor(draft); paintIris(); paintBar(); }],
    ['Ignore', null, 'cancel'],
  ]);
}
$('#eb-discard').addEventListener('click', discardEdit);
$('#eb-third').addEventListener('click', () => {
  readRows();
  if (isTask(draft)) { openShotList(); return; }                        // shot-list.js
  if (draft.obie) return;                                               // an Obie stays Important
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

// Mark done for the whole Take: every item ticked and the reminder done, or all undone. A
// repeating reminder moves on to its next occurrence instead, and the series goes on.
function toggleDone(t) {
  if (repeats(t.reminder)) { advanceRepeat(t.reminder); return; }
  const done = !isDone(t);
  t.blocks.forEach(b => { if (b.k === 'check') b.done = done; });
  if (t.reminder) t.reminder.done = done;
}

// The reminder picker is in reminders.js.

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
    lift.inert = true; lift.removeAttribute('tabindex');   // a picture of the card, not a second one to Tab to
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
    // An Obie is always Important, so the ring can't take it off one (DailiesViewModel).
    const important = sel.has('important') || !!target.obie;
    if (!!target.isImportant !== important) target.isImportant = important;
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
    else refocus();
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
    if (!t.obie) makeObie(t);
    else { t.obie = false; touch(t); }   // holding the Obie's Iris makes it a standard Take again, without asking
  }, 450) };
});
// A hold that moves (a scroll) or is cancelled is not a hold.
const dropHold = () => { if (irisHold && !irisHold.fired) { clearTimeout(irisHold.t); irisHold = null; } };
document.addEventListener('pointermove', e => { if (irisHold && Math.hypot(e.clientX - irisHold.x, e.clientY - irisHold.y) > 10) dropHold(); });
document.addEventListener('pointerup', () => { if (irisHold && !irisHold.fired) clearTimeout(irisHold.t); });
document.addEventListener('pointercancel', dropHold);
sidebar.addEventListener('click', e => {
  if (draft || focusRing) return;
  const label = e.target.closest('#takes .month-label');
  if (label) {   // a month label toggles that month's filter, in any mode
    const key = label.parentElement.dataset.month;
    filterMonth = filterMonth === key ? null : key;
    renderTakes();
    return;
  }
  // A dock button repaints the dock, so its click arrives here from a detached element:
  // only a press on something still in Dailies can be a press on empty space.
  if (!storyboard && (dock !== 'resting' || filterMonth) && sidebar.contains(e.target) && !e.target.closest('.card, .dock, .sheet-close')) { exitToResting(); return; }
  const ir = e.target.closest('.timeline .iris-wrap, #pinned .iris-wrap');
  if (ir) {
    if (irisHold?.fired) { irisHold = null; return; }
    irisHold = null;
    openFocusRing(takes.find(x => x.id === ir.dataset.iris), ir, false);
    return;
  }
  if (e.target.closest('.card a.tlink')) return;   // a link opens; anywhere else on the card edits it
  const card = e.target.closest('.timeline .card, #pinned .card');
  if (card && !e.target.closest('.thandle')) beginEdit(takes.find(x => x.id === card.dataset.take));
});
$('#take-editor-iris').addEventListener('click', () => openFocusRing(draft, $('#take-editor-iris'), true));
const newTake = () => beginEdit({ id: 't' + Date.now(), at: new Date().toISOString(), blocks: [{ k: 'text', text: '' }], isNote: true }, true);

// ---------- the dock (BottomDockView): resting, Sequence and Search ----------
// Resting: Add, the Storyboard, Sequence, Search. Sequence turns the dock into four filter
// toggles; Search into Cancel, a field and the magnifier. There is no exit button: clicking
// the heading, empty timeline or the blank part of a month row returns to resting, as a tap
// does on iOS. Escape does the same here, since a Mac has the key. A month label filters by
// that month in any mode. Nothing is saved: a Sequence is a live filter.
let dock = 'resting', storyboard = false, filterMonth = null, searchText = '';
const seq = { important: false, notes: false, tasks: false, tasksDone: false, reminders: false, remindersExpired: false };
const plainText = t => t.blocks.map(b => b.text).join('\n');

// SequenceFilter.matches: every active condition must hold.
function matches(t) {
  if (filterMonth && monthKey(t.at) !== filterMonth) return false;
  if (dock === 'searching') {
    const q = searchText.trim().toLowerCase();
    return !q || plainText(t).toLowerCase().includes(q);
  }
  if (dock !== 'filtering') return true;
  return (!seq.tasks || isTask(t)) && (!seq.reminders || !!t.reminder)
    && (!seq.notes || (!isTask(t) && !t.reminder)) && (!seq.tasksDone || isComplete(t))
    && (!seq.remindersExpired || isOverdue(t)) && (!seq.important || !!t.isImportant);
}

const ICON = {
  add: '<svg viewBox="0 0 24 24"><path d="M12 5v14M5 12h14"/></svg>',
  angle: '<svg viewBox="0 0 24 24"><path d="M5 18h14M5 18l9-11M10.5 18a6 6 0 0 0-1.9-4.4"/></svg>',
  sequence: '<svg viewBox="0 0 24 24"><circle cx="6.5" cy="12" r="2"/><circle cx="12" cy="12" r="2"/><circle cx="17.5" cy="12" r="2"/></svg>',
  search: '<svg viewBox="0 0 24 24"><circle cx="10.5" cy="10.5" r="5.5"/><path d="M15 15l4.5 4.5"/></svg>',
  cancel: '<svg viewBox="0 0 24 24"><path d="M6.5 6.5l11 11M17.5 6.5l-11 11"/></svg>',
  note: '<svg viewBox="0 0 24 24"><rect x="5" y="4" width="14" height="16" rx="2"/><path d="M8.5 9h7M8.5 12.5h7M8.5 16h4"/></svg>',
  task: '<svg viewBox="0 0 24 24"><rect x="4.5" y="4.5" width="15" height="15" rx="3"/><path d="M8.5 12.2l2.6 2.6 4.6-5.3"/></svg>',
  taskDone: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="8"/><path d="M8.5 12.2l2.6 2.6 4.6-5.3"/></svg>',
  bell: ICON_BELL,
  expired: '<svg viewBox="0 0 24 24"><circle cx="11" cy="12" r="7"/><path d="M11 8.5V12l2.4 1.6M20 7v5M20 15.2v.3"/></svg>',
};

function paintDock() {
  const bar = $('#takes-dock');
  announceDock();   // a11y.js
  bar.hidden = storyboard;   // the Storyboard covers Dailies and carries only its ×
  bar.dataset.mode = dock;
  const btn = (act, icon, label, extra = '') => `<button class="dock-btn${extra}" type="button" data-act="${act}" aria-label="${label}" title="${label}">${icon}</button>`;
  const tog = (act, icon, label, on, fill) => btn(act, icon, label, ` toggle${on ? ' on' : ''}" style="--fill: var(--iris-${fill})" aria-pressed="${on}`);
  if (dock === 'resting') {
    bar.innerHTML = btn('add', ICON.add, 'Add Take') + btn('storyboard', ICON.angle, 'Storyboard')
      + btn('sequence', ICON.sequence, 'Sequence') + btn('search', ICON.search, 'Search');
  } else if (dock === 'filtering') {
    bar.innerHTML = tog('important', ICON_IMPORTANT, 'Important filter', seq.important, 'important')
      + tog('notes', ICON.note, 'Notes filter', seq.notes, 'note')
      + tog('tasks', seq.tasksDone ? ICON.taskDone : ICON.task, seq.tasksDone ? 'Tasks filter, done only' : 'Tasks filter', seq.tasks, 'task')
      + tog('reminders', seq.remindersExpired ? ICON.expired : ICON.bell, seq.remindersExpired ? 'Reminders filter, expired only' : 'Reminders filter', seq.reminders, 'remind');
  } else if (!bar.querySelector('#take-search')) {
    // Built once per search, so typing never loses the caret to a repaint.
    bar.innerHTML = btn('cancel-search', ICON.cancel, 'Cancel search', ' filled')
      + '<input class="dock-search" id="take-search" type="search" placeholder="Search your Takes" aria-label="Search Takes" autocomplete="off" spellcheck="false">'
      + btn('focus-search', ICON.search, 'Search');
  }
}

function exitToResting() {
  dock = 'resting'; filterMonth = null; searchText = '';
  for (const k in seq) seq[k] = false;
  renderTakes();
}

// Toggle rules from UIState: Important stands alone; Notes clears Tasks and Reminders; Tasks
// or Reminders clears Notes; a long press (or right-click) gives Done-only or Expired-only,
// and a second one returns to plain on.
function tapFilter(k) {
  if (k === 'important') seq.important = !seq.important;
  else if (k === 'notes') { if (seq.notes) seq.notes = false; else Object.assign(seq, { notes: true, tasks: false, tasksDone: false, reminders: false, remindersExpired: false }); }
  else if (k === 'tasks') { if (seq.tasks) Object.assign(seq, { tasks: false, tasksDone: false }); else Object.assign(seq, { tasks: true, tasksDone: false, notes: false }); }
  else if (k === 'reminders') { if (seq.reminders) Object.assign(seq, { reminders: false, remindersExpired: false }); else Object.assign(seq, { reminders: true, remindersExpired: false, notes: false }); }
  renderTakes();
}
function holdFilter(k) {
  if (k === 'tasks') { if (seq.tasks && seq.tasksDone) seq.tasksDone = false; else Object.assign(seq, { tasks: true, tasksDone: true, notes: false }); }
  else if (k === 'reminders') { if (seq.reminders && seq.remindersExpired) seq.remindersExpired = false; else Object.assign(seq, { reminders: true, remindersExpired: true, notes: false }); }
  else return false;
  renderTakes();
  return true;
}

const takesDock = $('#takes-dock');
let filterHold = null;
// A swipe up on the dock opens Settings, as on iOS: it starts on the buttons, travels more
// than 30 up and drifts under 60 sideways. The click that ends it is not a tap.
let dockSwipe = null;
takesDock.addEventListener('pointerdown', e => { dockSwipe = { x: e.clientX, y: e.clientY, fired: false }; });
addEventListener('pointerup', e => {
  if (!dockSwipe) return;
  const dy = e.clientY - dockSwipe.y, dx = Math.abs(e.clientX - dockSwipe.x);
  // The flag only has to outlive the click that ends this gesture, which may never come.
  if (dy < -30 && dx < 60) { dockSwipe.fired = true; setTimeout(() => { dockSwipe = null; }, 400); clearTimeout(filterHold?.t); filterHold = null; openSettings(); }
  else dockSwipe = null;
});
takesDock.addEventListener('click', e => {
  if (dockSwipe?.fired) { dockSwipe = null; return; }
  dockSwipe = null;
  // The click that ends a long press is not a tap. The hold repaints the dock, so that click
  // may land on the dock itself rather than a button: clear the flag before anything else.
  if (filterHold?.fired) { filterHold = null; return; }
  const b = e.target.closest('[data-act]');
  if (!b) return;
  const act = b.dataset.act;
  if (act === 'add') newTake();
  else if (act === 'storyboard') { storyboard = true; renderTakes(); }
  else if (act === 'sequence') { dock = 'filtering'; renderTakes(); }
  else if (act === 'search') { dock = 'searching'; searchText = ''; renderTakes(); $('#take-search').focus(); }
  else if (act === 'cancel-search') exitToResting();
  else if (act === 'focus-search') $('#take-search').focus();
  else tapFilter(act);
});
takesDock.addEventListener('pointerdown', e => {
  filterHold = null;
  const b = e.target.closest('[data-act="tasks"], [data-act="reminders"]');
  if (!b || e.button !== 0) return;
  const hold = filterHold = { fired: false, t: setTimeout(() => { hold.fired = true; holdFilter(b.dataset.act); }, 400) };
});
const endFilterHold = () => { if (filterHold && !filterHold.fired) { clearTimeout(filterHold.t); filterHold = null; } };
takesDock.addEventListener('pointerup', endFilterHold);
takesDock.addEventListener('pointerleave', endFilterHold);
takesDock.addEventListener('contextmenu', e => {
  // A touch long press can raise contextmenu after the hold timer has already acted; it is
  // the same gesture, so it must not toggle a second time.
  if (filterHold?.fired) { e.preventDefault(); return; }
  const b = e.target.closest('[data-act]');
  if (b && holdFilter(b.dataset.act)) e.preventDefault();
});
takesDock.addEventListener('input', e => { if (e.target.id === 'take-search') { searchText = e.target.value; renderTakes(); } });
takesDock.addEventListener('keydown', e => { if (e.target.id === 'take-search' && e.key === 'Enter') e.target.blur(); });   // keeps the results
$('#sb-close').addEventListener('click', () => { storyboard = false; renderTakes(); });
document.addEventListener('keydown', e => {
  // An Escape the editor, the ring or the picker has already used is not this one.
  if (e.key !== 'Escape' || e.defaultPrevented || draft || focusRing || reminderFor || !ctx.hidden) return;
  if (storyboard) { storyboard = false; renderTakes(); }
  else if (dock !== 'resting' || filterMonth) exitToResting();
});

// ---------- Expand and Export (the Take menu) ----------
// Expanded Takes ignore the Preview setting and show in full. Kept per device, never synced.
let expanded = new Set(store.get('expanded', []));
function toggleExpanded(id) {
  if (expanded.has(id)) expanded.delete(id); else expanded.add(id);
  store.set('expanded', [...expanded].sort());
  renderTakes();
}

// TakeExporter's Markdown, oldest first, less the trailing data block, which is Core's to write.
function exportMarkdown(list, now = new Date()) {
  const pad = n => String(n).padStart(2, '0');
  const day = d => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  const sorted = [].concat(list).sort((a, b) => a.at.localeCompare(b.at));
  let out = `---\nexported: ${now.toISOString().replace(/\.\d{3}Z$/, 'Z')}\ntakes: ${sorted.length}\n---\n`;
  for (const t of sorted) {
    const made = day(new Date(t.at));
    let head;
    if (isTimeR(t.reminder)) {
      const r = new Date(t.reminder.when), w = t.reminder.weekdays || [];
      const every = repeats(t.reminder) ? ` · repeats ${REPEAT_LABEL[t.reminder.repeat].toLowerCase()}${w.length ? ` (${w.map(n => new Date(2026, 1, n).toLocaleDateString('en-GB', { weekday: 'short' })).join(', ')})` : ''}` : '';
      head = `Reminder — ${made} · 🔔 ${day(r)} ${pad(r.getHours())}:${pad(r.getMinutes())}${every}`;
    }
    else if (isPlaceR(t.reminder)) head = `Reminder — ${made} · 📍 ${t.reminder.name || 'Location'} · ${t.reminder.mode === 'leave' ? 'on leaving' : 'on arrival'}`;
    else if (isTask(t)) head = `Task — ${made}${isComplete(t) ? ' · ✓ Complete' : ''}`;
    else head = `Note — ${made}`;
    out += `\n## ${head}\n${textOf(t)}\n`;
  }
  return out;
}
// The shells hand this to a save panel or share sheet; the prototype downloads it.
const exportName = (now = new Date()) => `catchlight-${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')}.md`;
const exportTake = t => exportTakes([t]);
function exportTakes(list) {
  const now = new Date(), a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([exportMarkdown(list, now)], { type: 'text/markdown' }));
  a.download = exportName(now); a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 0);
}

// ---------- the Take menu (right-click, or long press on touch) ----------
// The iOS long-press menu, plus Expand into a Script (D-313). The Storyboard's is shorter:
// Mark Done, Important and Delete, as on iOS.
function takeMenu(id) {
  const t = takes.find(x => x.id === id);
  const items = [];
  if (!storyboard) items.push([expanded.has(id) ? 'Collapse Take' : 'Expand Take', () => toggleExpanded(id)]);
  if (canBeMarkedDone(t)) items.push([isDone(t) ? 'Mark Not Done' : 'Mark Done', () => { toggleDone(t); touch(t); }]);
  // An Obie stays Important, so its menu has nothing to offer here.
  if (!t.obie) items.push([t.isImportant ? 'Remove Important' : 'Make Important', () => {
    t.isImportant = !t.isImportant;
    if (!t.isImportant) noteFloor(t);
    touch(t);
  }]);
  if (!storyboard) {
    if (!t.obie) items.push(['Make Obie', () => makeObie(t)]);
    items.push(['Export Take', () => exportTake(t)]);
    items.push(['Expand into a Script', () => {
      takes = takes.filter(x => x !== t);
      forgetExpanded(t.id);
      saveTakes(); renderTakes(); newScript(linesToBlocks(textOf(t)));
    }]);
  }
  items.push(['Delete Take', null, 'danger']);
  return items;
}
// Making a Take the Obie when another already is asks first (RootView, owner copy 2026-06-17).
// Becoming the Obie makes it Important; Important can be taken off later (Take.isObie).
function makeObie(t) {
  const make = () => { takes.forEach(x => { x.obie = false; }); t.obie = true; t.isImportant = true; touch(t); };
  if (!takes.some(x => x.obie && x.id !== t.id)) { make(); return; }
  ask('Make this your Obie?', 'Your existing Obie returns to the timeline. Only one Take can be your Obie.', [['Make Obie', make], ['Cancel', null, 'cancel']]);
}
// Confirm before deleting (DeleteConfirmation): Delete first, then Cancel, as on iOS.
const askDelete = t => ask('Delete this Take?', 'This cannot be undone.', [['Delete', () => deleteTake(t.id), 'danger'], ['Cancel', null, 'cancel']]);
function touch(t) { t.modifiedAt = Date.now(); saveTakes(); renderTakes(); }
function forgetExpanded(id) { if (expanded.delete(id)) store.set('expanded', [...expanded].sort()); }
function deleteTake(id) {
  takes = takes.filter(x => x.id !== id);
  forgetExpanded(id);
  saveTakes(); renderTakes();
}

// Delete on a repeating reminder in Dailies asks which, as on iOS (owner 2026-06-21): Delete
// This Occurrence skips to the next one and the series goes on; Delete Series deletes the Take.
// It replaces Confirm before deleting, since it already asks. The Storyboard's menu has no
// such dialog on iOS, so there a repeating Take deletes like any other.
const asksWhichToDelete = t => !storyboard && repeats(t.reminder);
function askWhichToDelete(t) {
  ask('This is a repeating reminder.', 'Delete only the next occurrence, or the whole repeating series?', [
    ['Delete This Occurrence', () => {
      // Leave the editor first if this Take is open, or saving the draft would undo the skip.
      if (draft && original?.id === t.id) discardEdit();
      advanceRepeat(t.reminder); touch(t);
    }],
    ['Delete Series', () => deleteTake(t.id), 'danger'],
    ['Cancel', null, 'cancel'],
  ]);
}

// The alert (NSAlert on the Mac, .alert or .confirmationDialog on iOS; each shell draws its
// own). `actions` are [label, run, kind]; kind 'cancel' takes focus and Escape, 'danger' is red.
const alertBox = document.createElement('dialog');
alertBox.className = 'alert';
document.body.append(alertBox);
let alertActions = [];
function ask(title, message, actions) {
  alertActions = actions;
  alertBox.innerHTML = `<h2>${esc(title)}</h2><p>${esc(message)}</p><div class="alert-actions">${
    actions.map(([label, , kind], i) => `<button type="button" data-i="${i}"${kind ? ` class="${kind}"` : ''}>${esc(label)}</button>`).join('')}</div>`;
  alertBox.showModal();
  (alertBox.querySelector('.cancel') || alertBox.querySelector('button')).focus();
}
alertBox.addEventListener('click', e => {
  const b = e.target.closest('button[data-i]');
  if (!b) return;
  const run = alertActions[b.dataset.i][1];
  alertActions = []; alertBox.close();
  run && run();
});
// 'close' is queued after the action has run and repainted, so refocus() (a11y.js), which an
// open alert defers, now finds the new card or Iris (Make Obie, Delete This Occurrence).
alertBox.addEventListener('close', () => { alertActions = []; refocus(); });

// A Script made back into a Take: "- [ ]" lines become checklist items, the rest text.
function takeFromScript(s) {
  const blocks = [];
  for (const line of blocksToText(s.blocks).split('\n')) {
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
