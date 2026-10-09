'use strict';
// Three gestures from the iPhone (As-Built, D-274), loaded after takes.js:
//   • Swipe a Take in Dailies (SwipeActionRow): right for Done or Not done, left for Delete.
//   • Drag a Take by its ≡ handle when Dailies is arranged by hand (UIKitTimeline, D-195).
//   • Drag a checklist item by its ≡ handle in the editor (BlockEditorViewController).
// Both work with a finger, a pen or a mouse; on a trackpad a two-finger horizontal scroll
// swipes a row too, since that is the gesture a Mac has for it.

// ---------- swipe a Take ----------
const SW = { width: 42, snap: 0.55 * 42, tuck: 12, fade: 24 };   // SwipeActionRow's numbers, in points
let swipeOpen = null;        // { card, offset }: the row currently held open
let swipeSuppress = false;   // the click that ends a swipe is not a tap

const swipeCards = '#takes .card, #pinned .card';
const canSwipe = () => !draft && !focusRing && !storyboard;   // the Storyboard has no swipe on iOS

function actionsFor(card) {
  const t = takes.find(x => x.id === card.dataset.take);
  return {
    t,
    leading: t && canBeMarkedDone(t) ? (isDone(t) ? { label: L10N.t('Not done'), icon: '<path d="M9 7L5 11l4 4M5 11h9a5 5 0 0 1 0 10h-2"/>' } : { label: L10N.t('Done'), icon: '<path d="M5 12.5l4.5 4.5L19 7.5"/>' }) : null,
    trailing: { label: L10N.t('Delete'), icon: '<path d="M5 7h14M10 7V5h4v2M7 7l1 13h8l1-13"/>' },
  };
}

// The fill sits behind the card, pinned to the column's edge, and grows with the swipe.
function paintFill(card, offset) {
  let fill = card.parentElement.querySelector(`.swipe-fill[data-for="${card.dataset.take}"]`);
  if (!offset) { fill?.remove(); return; }
  const side = offset > 0 ? 'leading' : 'trailing', a = actionsFor(card)[side];
  if (!a) return;
  if (!fill || fill.dataset.side !== side) {
    fill?.remove();
    fill = document.createElement('button');
    fill.type = 'button'; fill.className = `swipe-fill ${side}`; fill.dataset.for = card.dataset.take; fill.dataset.side = side;
    fill.innerHTML = `<svg viewBox="0 0 24 24" aria-hidden="true">${a.icon}</svg><span>${a.label}</span>`;
    fill.setAttribute('aria-label', a.label);
    card.parentElement.insertBefore(fill, card);
  }
  // From the card's resting place: offsetLeft ignores the transform the swipe applies.
  const inset = side === 'leading' ? card.offsetLeft : card.parentElement.clientWidth - card.offsetLeft - card.offsetWidth;
  Object.assign(fill.style, {
    top: card.offsetTop + 'px', height: card.offsetHeight + 'px',
    width: inset + Math.abs(offset) + SW.tuck + 'px', opacity: Math.min(1, Math.abs(offset) / SW.fade),
    [side === 'leading' ? 'left' : 'right']: 0, [side === 'leading' ? 'right' : 'left']: 'auto',
  });
}

function setOffset(card, offset, animate) {
  card.classList.toggle('swipe-settle', !!animate);
  card.style.transform = offset ? `translateX(${offset}px)` : '';
  paintFill(card, offset);
}

function closeSwipe(animate = true) {
  if (!swipeOpen) return;
  const { card } = swipeOpen;
  swipeOpen = null;
  setOffset(card, 0, animate);
}

function commitSwipe(card, side) {
  const { t } = actionsFor(card);
  if (!t) return;
  // Held for a conflict choice: the row goes back and nothing changes.
  if (isHeld(t.id)) { swipeOpen = null; setOffset(card, 0, true); refuseHeld(t.id); return; }
  if (side === 'leading') { toggleDone(t); touch(t); return; }   // renderTakes rebuilds the row closed
  // A repeating reminder, or Confirm before deleting, asks first, and the row has to still be
  // there if the answer is no.
  if (asksWhichToDelete(t)) { swipeOpen = null; setOffset(card, 0, true); askWhichToDelete(t); return; }
  if (settings.confirmDelete) { swipeOpen = null; setOffset(card, 0, true); askDelete(t); return; }
  // Otherwise one continuous motion: the card slides off and the row goes with it.
  card.classList.add('swipe-off');
  card.style.transform = `translateX(-${card.parentElement.clientWidth + 200}px)`;
  card.parentElement.querySelector(`.swipe-fill[data-for="${t.id}"]`)?.style.setProperty('width', '100%');
  setTimeout(() => deleteTake(t.id), still.matches ? 0 : 280);
}

// Where a released swipe goes: commit past half the row (or 1.6 × the action), snap open past
// 55% of the action width, otherwise close.
function releaseSwipe(card, start, travel, offset) {
  const side = offset > 0 ? 'leading' : 'trailing';
  const commitAt = Math.max(card.offsetWidth * 0.5, SW.width * 1.6);
  if (offset && Math.abs(start + travel) >= commitAt && actionsFor(card)[side]) { swipeOpen = null; commitSwipe(card, side); return; }
  if (Math.abs(offset) >= SW.snap && actionsFor(card)[side]) {
    const open = offset > 0 ? SW.width : -SW.width;
    swipeOpen = { card, offset: open };
    setOffset(card, open, true);
  } else { swipeOpen = null; setOffset(card, 0, true); }
}

// Past the action width the card moves at half the finger's speed.
function dragOffset(card, raw) {
  if (raw > 0 && !actionsFor(card).leading) return 0;
  const a = Math.abs(raw), banded = a <= SW.width ? a : SW.width + (a - SW.width) * 0.5;
  return Math.sign(raw) * banded;
}

let swipe = null;
sidebar.addEventListener('pointerdown', e => {
  const card = e.target.closest(swipeCards);
  if (!card || !canSwipe() || e.button !== 0) return;
  if (swipeOpen && swipeOpen.card !== card) closeSwipe();   // one open row at a time
  swipe = { card, x: e.clientX, y: e.clientY, id: e.pointerId, start: swipeOpen?.card === card ? swipeOpen.offset : 0, active: false };
});
sidebar.addEventListener('pointermove', e => {
  if (!swipe || e.pointerId !== swipe.id) return;
  const dx = e.clientX - swipe.x, dy = e.clientY - swipe.y;
  if (!swipe.active) {
    if (Math.abs(dx) < 8 || Math.abs(dx) <= Math.abs(dy)) { if (Math.abs(dy) > 8) swipe = null; return; }   // a vertical stroke scrolls
    swipe.active = true;
    try { swipe.card.setPointerCapture(e.pointerId); } catch {}   // the pointer may already be gone
    clearTimeout(irisHold?.t); irisHold = null;   // a swipe is not an Iris hold or a long press
    if (press) { clearTimeout(press.t); press = null; }
  }
  swipe.offset = dragOffset(swipe.card, swipe.start + dx);
  setOffset(swipe.card, swipe.offset, false);
});
const endSwipe = e => {
  if (!swipe || e.pointerId !== swipe.id) return;
  const s = swipe; swipe = null;
  if (!s.active) return;
  // Swallow the click that ends the swipe; if the row was removed it never comes, so the
  // flag must not outlive the gesture.
  swipeSuppress = true;
  setTimeout(() => { swipeSuppress = false; }, 400);
  releaseSwipe(s.card, s.start, e.clientX - s.x, s.offset || 0);
};
sidebar.addEventListener('pointerup', endSwipe);
sidebar.addEventListener('pointercancel', e => { if (swipe?.active) { swipe = null; closeSwipe(); } else swipe = null; });

// Trackpad: a horizontal two-finger scroll over a card swipes it; the gesture ends when the
// scroll stops.
let wheelSwipe = null;
sidebar.addEventListener('wheel', e => {
  const card = e.target.closest(swipeCards);
  if (!card || !canSwipe() || Math.abs(e.deltaX) <= Math.abs(e.deltaY)) return;
  e.preventDefault();   // no browser back/forward on a row
  if (!wheelSwipe || wheelSwipe.card !== card) {
    if (swipeOpen && swipeOpen.card !== card) closeSwipe();
    wheelSwipe = { card, start: swipeOpen?.card === card ? swipeOpen.offset : 0, travel: 0 };
  }
  wheelSwipe.travel -= e.deltaX;
  wheelSwipe.offset = dragOffset(card, wheelSwipe.start + wheelSwipe.travel);
  setOffset(card, wheelSwipe.offset, false);
  clearTimeout(wheelSwipe.t);
  wheelSwipe.t = setTimeout(() => { const w = wheelSwipe; wheelSwipe = null; releaseSwipe(w.card, w.start, w.travel, w.offset); }, 140);
}, { passive: false });

// Clicks: the one ending a swipe does nothing; a click on an open card closes it without
// opening the editor; a click on the revealed fill commits its action.
sidebar.addEventListener('click', e => {
  const fill = e.target.closest('.swipe-fill');
  if (fill) {
    e.stopImmediatePropagation();
    const card = fill.parentElement.querySelector(`[data-take="${fill.dataset.for}"]`);
    swipeOpen = null;
    if (card) commitSwipe(card, fill.dataset.side);
    return;
  }
  if (swipeSuppress) { swipeSuppress = false; e.stopImmediatePropagation(); e.preventDefault(); return; }
  // A click on an open card only closes it: no editor, and no link followed.
  if (swipeOpen && e.target.closest(swipeCards) === swipeOpen.card) { e.stopImmediatePropagation(); e.preventDefault(); closeSwipe(); }
}, true);

// A repaint rebuilds the cards, so no row stays open across one.
new MutationObserver(() => { if (swipeOpen && !swipeOpen.card.isConnected) swipeOpen = null; })
  .observe($('#takes'), { childList: true });

// ---------- arrange Takes by hand (Manual, D-195) ----------
// Hold the ≡ handle for 0.25s, still, and the card lifts (TimelineDragHandle.liftDelay): moving
// more than 10px first lets the stroke go, as a scroll does on iOS. The lifted card follows the
// pointer, a gap of its size moves between the others, and the drop writes one Take's
// manualOrder (commitReorder). Escape puts it back. Dropped where it began, nothing is written.
const LIFT = { delay: 250, slack: 10 };
let arrange = null;
const takeList = $('#takes');
takeList.addEventListener('pointerdown', e => {
  const handle = e.target.closest('.thandle');
  if (!handle || e.button !== 0 || !canReorder() || draft) return;
  e.stopPropagation();   // a press on the handle is not a swipe, a long press or a tap on the card
  e.preventDefault();
  const card = handle.closest('.card');
  try { handle.setPointerCapture(e.pointerId); } catch {}
  arrange = { card, x: e.clientX, y: e.clientY, id: e.pointerId, lifted: false };
  arrange.t = setTimeout(() => liftCard(arrange), LIFT.delay);
});
function liftCard(a) {
  if (!a || a !== arrange) return;
  const { card } = a, cs = getComputedStyle(card);
  a.lifted = true;
  a.gap = document.createElement('div');
  a.gap.className = 'card-gap';
  a.gap.style.height = card.offsetHeight + 'px';
  a.gap.style.marginBottom = cs.marginBottom;
  a.top = card.offsetTop; a.scroll = takeList.scrollTop;
  card.before(a.gap);
  Object.assign(card.style, { position: 'absolute', left: card.offsetLeft + 'px', width: card.offsetWidth + 'px', top: a.top + 'px', margin: '0' });
  card.classList.add('arranging');
  takeList.classList.add('arranging');
}
takeList.addEventListener('pointermove', e => {
  const a = arrange;
  if (!a || e.pointerId !== a.id) return;
  if (!a.lifted) {
    if (Math.hypot(e.clientX - a.x, e.clientY - a.y) > LIFT.slack) { clearTimeout(a.t); arrange = null; }
    return;
  }
  a.py = e.clientY;
  followPointer(a);
  // Near the top or bottom of the list it scrolls, as the iOS timeline does under a held card.
  const box = takeList.getBoundingClientRect(), edge = 48;
  a.speed = a.py < box.top + edge ? -1 : a.py > box.bottom - edge ? 1 : 0;
  if (a.speed && !a.scroller) a.scroller = setInterval(() => {
    if (!a.speed || arrange !== a) { clearInterval(a.scroller); a.scroller = null; return; }
    takeList.scrollTop += a.speed * 12; followPointer(a);
  }, 16);
});
takeList.addEventListener('scroll', () => { if (arrange?.lifted) followPointer(arrange); });
// The card sits under the pointer in the list's content, scrolled or not; the gap moves to the
// slot its centre is over.
function followPointer(a) {
  const top = a.top + (a.py ?? a.y) - a.y + takeList.scrollTop - a.scroll;
  a.card.style.top = top + 'px';
  const centre = top + a.card.offsetHeight / 2;
  const others = [...takeList.querySelectorAll('.card')].filter(c => c !== a.card);
  const target = others.filter(c => c.offsetTop + c.offsetHeight / 2 < centre).length;
  const current = others.filter(c => c.compareDocumentPosition(a.gap) & Node.DOCUMENT_POSITION_FOLLOWING).length;
  if (current !== target) flip(others, () => { if (others[target]) others[target].before(a.gap); else takeList.append(a.gap); });
}
function dropCard(e, cancel) {
  const a = arrange;
  if (!a || (e && e.pointerId !== a.id)) return;
  clearTimeout(a.t); clearInterval(a.scroller); arrange = null;
  if (!a.lifted) return;
  const id = a.card.dataset.take;
  a.gap.replaceWith(a.card);
  a.card.style.cssText = ''; a.card.classList.remove('arranging'); takeList.classList.remove('arranging');
  if (cancel) { renderTakes(); return; }
  commitReorder(id, [...takeList.querySelectorAll('.card')].map(c => c.dataset.take));
}
takeList.addEventListener('pointerup', e => dropCard(e, false));
takeList.addEventListener('pointercancel', e => dropCard(e, true));
document.addEventListener('keydown', e => { if (e.key === 'Escape' && arrange?.lifted) { e.stopPropagation(); dropCard(null, true); } }, true);
// The keyboard route: ⌥↑ and ⌥↓ on a focused handle move the Take one place, as VoiceOver's
// Move up and Move down do on iOS, and keep focus on it.
takeList.addEventListener('keydown', e => {
  const handle = e.target.closest('.thandle');
  if (!handle || !e.altKey || (e.key !== 'ArrowUp' && e.key !== 'ArrowDown')) return;
  e.preventDefault();
  const ids = [...takeList.querySelectorAll('.card')].map(c => c.dataset.take);
  const id = handle.closest('.card').dataset.take, from = ids.indexOf(id), to = from + (e.key === 'ArrowUp' ? -1 : 1);
  if (to < 0 || to >= ids.length) return;   // already at an end
  ids.splice(from, 1); ids.splice(to, 0, id);
  commitReorder(id, ids);
  takeList.querySelector(`[data-take="${id}"] .thandle`)?.focus();
});

// ---------- drag a checklist item ----------
// The handle starts the drag on the first movement, with no hold. The row lifts to 1.02 with
// no shadow (owner, on device), follows the pointer, and a gap of its height moves to the slot
// where the number of other rows above its centre says it belongs. Text blocks have no
// handle but count as slots. The new order is saved with the edit, so a drag that ends where
// it began writes nothing (D-250).
let reorder = null;
rows.addEventListener('pointerdown', e => {
  const handle = e.target.closest('.ehandle');
  if (!handle || e.button !== 0) return;
  e.preventDefault();
  const row = handle.closest('.erow');
  try { handle.setPointerCapture(e.pointerId); } catch {}
  reorder = { row, y: e.clientY, id: e.pointerId, started: false };
});
rows.addEventListener('pointermove', e => {
  if (!reorder || e.pointerId !== reorder.id) return;
  const { row } = reorder;
  if (!reorder.started) {
    if (Math.abs(e.clientY - reorder.y) < 2) return;
    reorder.started = true;
    const gap = document.createElement('div');
    gap.className = 'erow-gap'; gap.style.height = row.offsetHeight + 'px';
    reorder.gap = gap; reorder.top = row.offsetTop;
    row.before(gap);
    Object.assign(row.style, { position: 'absolute', left: row.offsetLeft + 'px', width: row.offsetWidth + 'px', top: reorder.top + 'px' });
    row.classList.add('lifted');
    rows.classList.add('reordering');
  }
  const top = reorder.top + e.clientY - reorder.y;
  row.style.top = top + 'px';
  const centre = top + row.offsetHeight / 2;
  const others = [...rows.children].filter(r => r !== row && r !== reorder.gap);
  const target = others.filter(r => r.offsetTop + r.offsetHeight / 2 < centre).length;
  const current = others.filter(r => r.compareDocumentPosition(reorder.gap) & Node.DOCUMENT_POSITION_FOLLOWING).length;
  if (current !== target) flip(others, () => { if (others[target]) others[target].before(reorder.gap); else rows.append(reorder.gap); });
});
function endReorder(e) {
  if (!reorder || e.pointerId !== reorder.id) return;
  const { row, gap, started } = reorder;
  reorder = null;
  if (!started) return;
  gap.replaceWith(row);
  row.style.cssText = '';
  row.classList.remove('lifted');
  rows.classList.remove('reordering');
  readRows();   // draft.blocks now follows the rows' order; saved, or not, with the edit
}
rows.addEventListener('pointerup', endReorder);
rows.addEventListener('pointercancel', endReorder);

// Neighbours slide to their new places rather than jumping (0.16s, as on iOS).
function flip(els, change) {
  const before = new Map(els.map(el => [el, el.getBoundingClientRect().top]));
  change();
  if (still.matches) return;
  for (const el of els) {
    const d = before.get(el) - el.getBoundingClientRect().top;
    if (!d) continue;
    el.style.transition = 'none'; el.style.transform = `translateY(${d}px)`;
    requestAnimationFrame(() => { el.style.transition = 'transform .16s ease'; el.style.transform = ''; });
  }
}

// The keyboard route, as VoiceOver's Move up and Move down on iOS: ⌥↑ and ⌥↓ move a checklist
// item past the next checklist item, skipping text blocks.
rows.addEventListener('keydown', e => {
  if (!e.altKey || (e.key !== 'ArrowUp' && e.key !== 'ArrowDown')) return;
  const row = e.target.closest('.erow.check');
  if (!row) return;
  e.preventDefault();
  const all = [...rows.children], checks = all.filter(r => r.classList.contains('check'));
  const k = checks.indexOf(row), to = checks[e.key === 'ArrowUp' ? k - 1 : k + 1];
  if (!to) return;
  const caret = getSelection().focusOffset;   // before the move: moving the row drops the selection
  if (e.key === 'ArrowUp') to.before(row); else to.after(row);
  readRows();
  focusRow([...rows.children].indexOf(row), caret);
});
