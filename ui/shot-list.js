'use strict';
// The Shot List Angle (ShotListView.swift): the Take being edited, full window, as a list to
// work through. Loaded after gestures.js. It opens from the editor bar's checklist button, only
// for a Take with a checklist item, and × is the only way out (Escape too, since a Mac has the
// key): closing saves the edit and ends it. There is no text editing, no adding and no counts;
// renaming and adding stay in the editor. Links in the text are live, as on the cards.
//   • Tick an item by its checkbox (the row itself does nothing).
//   • Swipe an item: right for Done or Not done, left for Delete, which doesn't ask.
//   • Drag an item by its ≡ handle; prose rows can be passed but not dragged.
//   • With an item's checkbox focused: ⌥↑ and ⌥↓ move it past the next block, ⌫ deletes it
//     (VoiceOver's Move up, Move down and Delete item).
// Every change goes straight into the draft. If the last item goes, the Take is no longer a
// task and the Shot List closes itself, saving the edit.

const shot = document.createElement('section');
shot.id = 'shot-list'; shot.className = 'shot-list'; shot.hidden = true;
shot.setAttribute('role', 'dialog'); shot.setAttribute('aria-modal', 'true'); shot.setAttribute('aria-label', 'Shot List');
shot.innerHTML = `<header class="sl-head"><h2>Shot List</h2>
  <button class="sl-close" type="button" aria-label="Close Shot List"><svg viewBox="0 0 24 24"><path d="M6.5 6.5l11 11M17.5 6.5l-11 11"/></svg></button></header>
  <div class="sl-rows"></div>`;
document.body.append(shot);
const slRows = shot.querySelector('.sl-rows');
const shotListOpen = () => !shot.hidden;
const SL = { width: 64, snap: 0.55 * 64 };   // the Shot List's SwipeActionRow numbers
let slOpen = null;                            // { item, offset }: the row held open

function openShotList() {
  shot.classList.toggle('dark', !!(draft.obie || draft.isImportant));   // the Take's own card colour
  shot.hidden = false;
  paintShotList();
  shot.querySelector('.sl-close').focus();
}
function closeShotList() {
  shot.hidden = true; slRows.innerHTML = ''; slOpen = null;
  commitEdit();
}
shot.querySelector('.sl-close').addEventListener('click', closeShotList);
document.addEventListener('keydown', e => {   // wherever focus is: a click on blank space drops it to the page
  if (e.key === 'Escape' && shotListOpen() && !alertBox.open) { e.preventDefault(); closeShotList(); }
});

function paintShotList(focusIndex) {
  slOpen = null;
  slRows.innerHTML = draft.blocks.map((b, i) => b.k === 'check'
    ? `<div class="sl-item" data-i="${i}"><div class="sl-row${b.done ? ' ticked' : ''}">
        <button class="sl-box" type="button" role="checkbox" aria-checked="${!!b.done}"
          ${b.text.trim() ? `aria-labelledby="sl-text-${i}"` : 'aria-label="Item"'}
          title="${b.done ? 'Untick' : 'Tick'} · ⌥↑ ⌥↓ to move · ⌫ to delete"></button>
        <span class="sl-text" id="sl-text-${i}">${linkify(b.text)}</span>
        <span class="sl-handle" aria-label="Reorder item" role="img"></span></div></div>`
    : `<div class="sl-prose" data-i="${i}">${linkify(b.text)}</div>`).join('');
  if (focusIndex != null) slRows.querySelector(`.sl-item[data-i="${focusIndex}"] .sl-box`)?.focus();
}

// Any change: repaint here and in the editor behind, and close if the Take stopped being a task.
function shotChanged(focusIndex) {
  if (!draft.blocks.length) draft.blocks.push({ k: 'text', text: '' });
  paintEditor();   // takes.js: the editor rows, Iris and bar (which raises All tasks done)
  if (!isTask(draft)) { closeShotList(); return; }
  paintShotList(focusIndex);
}
function tick(i) { const b = draft.blocks[i]; b.done = !b.done; shotChanged(i); }
function removeItem(i) { draft.blocks.splice(i, 1); shotChanged(); }
function moveBlock(i, to) {
  if (to < 0 || to >= draft.blocks.length) return;
  const [b] = draft.blocks.splice(i, 1);
  draft.blocks.splice(to, 0, b);
  shotChanged(to);
}

let slSuppress = false;   // the click that ends a swipe is not a click
slRows.addEventListener('click', e => {
  if (slSuppress) { slSuppress = false; e.preventDefault(); return; }   // nor does it follow a link it started on
  const fill = e.target.closest('.sl-fill');
  if (fill) { commitShotSwipe(fill.closest('.sl-item'), fill.dataset.side); return; }
  const box = e.target.closest('.sl-box');
  if (slOpen) { e.preventDefault(); closeShotSwipe(); return; }   // a click on an open row closes it, and follows no link
  if (box) tick(+box.closest('.sl-item').dataset.i);
});
slRows.addEventListener('keydown', e => {
  const box = e.target.closest('.sl-box');
  if (!box) return;
  const i = +box.closest('.sl-item').dataset.i;
  if (e.altKey && (e.key === 'ArrowUp' || e.key === 'ArrowDown')) { e.preventDefault(); moveBlock(i, i + (e.key === 'ArrowUp' ? -1 : 1)); }
  else if (e.key === 'Backspace' || e.key === 'Delete') { e.preventDefault(); removeItem(i); }
});

// ---------- swipe an item ----------
function shotFill(item, offset) {
  let fill = item.querySelector('.sl-fill');
  if (!offset) { fill?.remove(); return; }
  const side = offset > 0 ? 'leading' : 'trailing';
  if (!fill || fill.dataset.side !== side) {
    fill?.remove();
    const done = draft.blocks[item.dataset.i].done;
    const [label, icon] = side === 'leading'
      ? (done ? ['Not done', '<path d="M9 7L5 11l4 4M5 11h9a5 5 0 0 1 0 10h-2"/>'] : ['Done', '<path d="M5 12.5l4.5 4.5L19 7.5"/>'])
      : ['Delete', '<path d="M5 7h14M10 7V5h4v2M7 7l1 13h8l1-13"/>'];
    fill = document.createElement('button');
    fill.type = 'button'; fill.className = `sl-fill swipe-fill ${side}`; fill.dataset.side = side;
    fill.setAttribute('aria-label', label);
    fill.innerHTML = `<svg viewBox="0 0 24 24" aria-hidden="true">${icon}</svg><span>${label}</span>`;
    item.prepend(fill);
  }
  fill.style.width = Math.abs(offset) + 'px';
}
function setShotOffset(item, offset, animate) {
  const row = item.querySelector('.sl-row');
  row.classList.toggle('swipe-settle', !!animate);
  row.style.transform = offset ? `translateX(${offset}px)` : '';
  shotFill(item, offset);
}
function closeShotSwipe() { if (slOpen) { setShotOffset(slOpen.item, 0, true); slOpen = null; } }
function commitShotSwipe(item, side) {
  slOpen = null;
  const i = +item.dataset.i;
  if (side === 'leading') { tick(i); return; }
  // Delete slides the row off as it goes (0.28s), then the item leaves the draft. The block is
  // found again by identity then, since another change may have moved it or closed the list.
  const block = draft.blocks[i], row = item.querySelector('.sl-row');
  row.classList.add('swipe-off'); row.style.transform = `translateX(-${item.clientWidth + 40}px)`;
  shotFill(item, -item.clientWidth);
  setTimeout(() => {
    const at = shotListOpen() && draft ? draft.blocks.indexOf(block) : -1;
    if (at >= 0) removeItem(at);
  }, still.matches ? 0 : 280);
}
function releaseShotSwipe(item, start, travel, offset) {
  const commitAt = Math.max(item.clientWidth / 2, 1.6 * SL.width);
  if (Math.abs(travel) >= commitAt && offset) { commitShotSwipe(item, offset > 0 ? 'leading' : 'trailing'); return; }
  if (Math.abs(offset) > SL.snap) { const o = Math.sign(offset) * SL.width; setShotOffset(item, o, true); slOpen = { item, offset: o }; return; }
  setShotOffset(item, 0, true);
  if (slOpen?.item === item) slOpen = null;
}
let slSwipe = null;
slRows.addEventListener('pointerdown', e => {
  const item = e.target.closest('.sl-item');
  if (!item || e.button !== 0 || e.target.closest('.sl-handle, .sl-box, .sl-fill')) return;
  if (slOpen && slOpen.item !== item) closeShotSwipe();   // one open row at a time
  slSwipe = { item, x: e.clientX, y: e.clientY, id: e.pointerId, start: slOpen?.item === item ? slOpen.offset : 0, active: false };
});
slRows.addEventListener('pointermove', e => {
  const s = slSwipe;
  if (!s || e.pointerId !== s.id) return;
  const dx = e.clientX - s.x, dy = e.clientY - s.y;
  if (!s.active) {
    if (Math.abs(dx) < 8 || Math.abs(dx) <= Math.abs(dy)) { if (Math.abs(dy) > 8) slSwipe = null; return; }
    s.active = true;
    try { s.item.setPointerCapture(e.pointerId); } catch {}
  }
  s.offset = Math.max(-s.item.clientWidth, Math.min(s.item.clientWidth, s.start + dx));
  setShotOffset(s.item, s.offset, false);
});
const endShotSwipe = e => {
  const s = slSwipe;
  if (!s || e.pointerId !== s.id) return;
  slSwipe = null;
  if (!s.active) return;
  slSuppress = true;
  setTimeout(() => { slSuppress = false; }, 400);   // no click comes if the row was removed
  releaseShotSwipe(s.item, s.start, e.clientX - s.x, s.offset || 0);
};
slRows.addEventListener('pointerup', endShotSwipe);
slRows.addEventListener('pointercancel', e => { if (slSwipe?.active) setShotOffset(slSwipe.item, 0, true); slSwipe = null; });
// Trackpad: a horizontal two-finger scroll swipes the row under the pointer.
let slWheel = null;
slRows.addEventListener('wheel', e => {
  const item = e.target.closest('.sl-item');
  if (!item || Math.abs(e.deltaX) <= Math.abs(e.deltaY)) return;
  e.preventDefault();
  if (!slWheel || slWheel.item !== item) {
    if (slOpen && slOpen.item !== item) closeShotSwipe();
    slWheel = { item, start: slOpen?.item === item ? slOpen.offset : 0, travel: 0 };
  }
  slWheel.travel -= e.deltaX;
  slWheel.offset = Math.max(-item.clientWidth, Math.min(item.clientWidth, slWheel.start + slWheel.travel));
  setShotOffset(item, slWheel.offset, false);
  clearTimeout(slWheel.t);
  slWheel.t = setTimeout(() => { const w = slWheel; slWheel = null; releaseShotSwipe(w.item, w.start, w.travel, w.offset); }, 140);
}, { passive: false });

// ---------- drag an item by its handle ----------
// Starts on the first movement, no hold. The row lifts above the others and a gap of its height
// moves to the slot its centre is over (0.18s); prose rows count as slots.
let slDrag = null;
slRows.addEventListener('pointerdown', e => {
  const handle = e.target.closest('.sl-handle');
  if (!handle || e.button !== 0) return;
  e.preventDefault();
  const item = handle.closest('.sl-item');
  try { handle.setPointerCapture(e.pointerId); } catch {}
  slDrag = { item, y: e.clientY, id: e.pointerId, started: false };
});
slRows.addEventListener('pointermove', e => {
  const d = slDrag;
  if (!d || e.pointerId !== d.id) return;
  if (!d.started) {
    if (Math.abs(e.clientY - d.y) < 2) return;
    d.started = true;
    d.gap = document.createElement('div');
    d.gap.className = 'sl-gap'; d.gap.style.height = d.item.offsetHeight + 'px';
    d.top = d.item.offsetTop;
    d.item.before(d.gap);
    Object.assign(d.item.style, { position: 'absolute', left: d.item.offsetLeft + 'px', width: d.item.offsetWidth + 'px', top: d.top + 'px' });
    d.item.classList.add('lifted');
    slRows.classList.add('reordering');
  }
  const top = d.top + e.clientY - d.y;
  d.item.style.top = top + 'px';
  const centre = top + d.item.offsetHeight / 2;
  const others = [...slRows.children].filter(r => r !== d.item && r !== d.gap);
  const target = others.filter(r => r.offsetTop + r.offsetHeight / 2 < centre).length;
  const current = others.filter(r => r.compareDocumentPosition(d.gap) & Node.DOCUMENT_POSITION_FOLLOWING).length;
  if (current !== target) flip(others, () => { if (others[target]) others[target].before(d.gap); else slRows.append(d.gap); });
});
function endShotDrag(e) {
  const d = slDrag;
  if (!d || e.pointerId !== d.id) return;
  slDrag = null;
  if (!d.started) return;
  const from = +d.item.dataset.i;
  const to = [...slRows.children].filter(r => r !== d.item).indexOf(d.gap);
  d.gap.remove(); d.item.style.cssText = ''; d.item.classList.remove('lifted'); slRows.classList.remove('reordering');
  if (to === from) { paintShotList(); return; }   // dropped where it began: nothing changes
  moveBlock(from, to);
}
slRows.addEventListener('pointerup', endShotDrag);
slRows.addEventListener('pointercancel', endShotDrag);
