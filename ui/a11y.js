'use strict';
// The timeline by keyboard and screen reader, as the iOS rows speak to VoiceOver
// (TakeRowView.accessibilityLabel, irisAccessibilityLabel, BottomDockView's announcements).
// Loaded after links.js and before takes.js, whose cards read the labels here.
//   • Every card and every Iris is a stop on Tab. A card reads its first line (links and email
//     addresses spoken as "Link to catchlight.app", "Email to bob at example.com"), then its
//     state, then its reminder. An Iris reads "Iris, <first line>", Obie, then what it carries.
//   • On a card: Return or Space edits it; the context-menu key or ⇧F10 opens its menu, whose
//     items Tab and the arrow keys walk, and Escape closes.
//   • On an Iris: Return or Space opens the Focus-ring; ⌥Return does what holding it does
//     (make this the Obie, or a standard Take again), standing in for VoiceOver's named action.
//   • A change of dock mode is announced, and closing the editor puts focus back on the card.

// "Buy film. Link to catchlight.app and 1 more link. Email to bob at example.com": the user's
// words with the links taken out, then where they go (spokenLine, VC1 and VC4).
function spokenLine(line) {
  const found = detectLinks(line);
  if (!found.length) return line;
  let words = '', at = 0;
  for (const l of found) { words += line.slice(at, l.start); at = l.end; }
  words = (words + line.slice(at)).split(/\s+/).filter(Boolean).join(' ');
  const web = found.filter(l => !l.url.startsWith('mailto:')), mail = found.filter(l => l.url.startsWith('mailto:'));
  const more = (n, one, many) => n === 2 ? ` and 1 more ${one}` : n > 2 ? ` and ${n - 1} more ${many}` : '';
  const phrases = [];
  if (web.length) {
    let host = ''; try { host = new URL(web[0].url).host.replace(/^www\./, ''); } catch {}
    if (host) phrases.push(`Link to ${host}${more(web.length, 'link', 'links')}`);
  }
  if (mail.length) phrases.push(`Email to ${mail[0].url.slice(7).replace('@', ' at ')}${more(mail.length, 'email', 'emails')}`);
  return [words, ...phrases].filter(Boolean).join('. ') || line;
}

// The state part of a card's label (statusDescription).
function statusDescription(t) {
  const parts = [];
  if (t.obie) parts.push('Obie, your pinned Take');
  if (isTask(t)) {
    const checks = t.blocks.filter(b => b.k === 'check');
    parts.push(`Task, ${checks.filter(b => b.done).length} of ${checks.length} complete`);
  }
  const r = t.reminder;
  if (isTimeR(r)) { parts.push('Reminder set'); if (isOverdue(t)) parts.push('Overdue'); }
  if (isPlaceR(r)) {
    const arrive = r.mode !== 'leave';
    parts.push(r.notify !== false ? (arrive ? 'Reminds on arrival' : 'Reminds on leaving') : (arrive ? 'Place set, arrival, silent' : 'Place set, leaving, silent'));
  }
  if (t.isNote && !isTask(t) && !r) parts.push('Note');
  return parts.join('. ');
}

const firstLine = t => (t.blocks[0]?.text ?? '').split('\n')[0];
// The card: first line, state, and the reminder's "when" (time reminders only, as on iOS).
const takeLabel = t => [spokenLine(firstLine(t)), statusDescription(t), isTimeR(t.reminder) ? reminderLine(t.reminder) : ''].filter(Boolean).join('. ');

// The Iris: named for its Take so one Iris can be told from another (VC2), cut to 40
// characters at a word.
function irisLabel(t) {
  let name = spokenLine(firstLine(t));
  if (name.length > 40) { const cut = name.slice(0, 40); name = (cut.lastIndexOf(' ') > 0 ? cut.slice(0, cut.lastIndexOf(' ')) : cut) + '…'; }
  const activity = [t.isImportant && 'Important', t.isNote && 'Note', isTask(t) && (isComplete(t) ? 'completed Task' : 'Task'), t.reminder && 'Reminder'].filter(Boolean).join(', ');
  return [name ? `Iris, ${name}` : 'Iris', t.obie && 'Obie: your pinned Take', activity].filter(Boolean).join('. ');
}
const irisHint = t => t.obie ? 'Opens the Focus ring. ⌥Return turns this back into a standard Take.' : 'Opens the Focus ring. ⌥Return makes this your Obie.';

// What takeCard adds to a card and its Iris. The card is a named group, not a button: a button's
// contents are hidden from a screen reader, and the Iris and the links inside have to stay
// reachable.
const cardA11y = t => `tabindex="0" role="group" aria-roledescription="Take" aria-haspopup="menu" aria-label="${esc(takeLabel(t))}"`;
const irisA11y = t => `tabindex="0" role="button" aria-label="${esc(irisLabel(t))}" title="${esc(irisHint(t))}"`;

// ---------- keys ----------
let returnFocusTo = null;   // the card to focus again when the editor closes
document.addEventListener('mousedown', () => { returnFocusTo = null; }, true);   // the pointer took over
const takeSidebar = document.getElementById('sidebar');
takeSidebar.addEventListener('keydown', e => {
  if (draft || focusRing) return;
  const ir = e.target.closest('.iris-wrap[data-iris]');
  if (ir && (e.key === 'Enter' || e.key === ' ')) {
    e.preventDefault(); e.stopPropagation();
    const t = takes.find(x => x.id === ir.dataset.iris);
    if (e.altKey && e.key === 'Enter' && !storyboard) {
      returnFocusTo = { id: t.id, iris: true };
      if (t.obie) { t.obie = false; touch(t); } else makeObie(t);
      refocus();
    } else { returnFocusTo = { id: t.id, iris: true }; openFocusRing(t, ir, false); }
    return;
  }
  const card = e.target === e.target.closest('.card[data-take]') ? e.target : null;
  if (!card) return;
  if (e.key === 'Enter' || e.key === ' ') {
    e.preventDefault();
    returnFocusTo = { id: card.dataset.take };
    beginEdit(takes.find(x => x.id === card.dataset.take));
  } else if (e.key === 'ContextMenu' || (e.shiftKey && e.key === 'F10')) {
    e.preventDefault();
    const r = card.getBoundingClientRect();
    returnFocusTo = { id: card.dataset.take };
    if (openCtx(card, r.left + 24, r.top + 24)) ctx.querySelector('button')?.focus();
  }
});
// The menu by keyboard: arrows move, Escape closes and goes back to the card.
ctx.addEventListener('keydown', e => {
  const items = [...ctx.querySelectorAll('button')], i = items.indexOf(document.activeElement);
  if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); items[(i + (e.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length]?.focus(); }
  else if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); ctx.hidden = true; refocus(); }
});
// Tab out of the menu closes it, as a native menu does; focus goes where Tab sent it. An item's
// click or a press elsewhere hides the menu first, so this only sees focus leaving an open one.
ctx.addEventListener('focusout', e => {
  if (!ctx.hidden && !ctx.contains(e.relatedTarget)) { ctx.hidden = true; returnFocusTo = null; }
});
// After a repaint the old card is gone; focus its replacement.
function refocus() {
  const f = returnFocusTo;
  if (!f || draft || alertBox?.open) return;
  returnFocusTo = null;
  const card = document.querySelector(`#takes [data-take="${f.id}"], #pinned [data-take="${f.id}"]`);
  (f.iris ? card?.querySelector('.iris-wrap') : card)?.focus();
}

// Dock changes, spoken (BottomDockView): one polite live region, set only on a change.
const dockSays = document.createElement('div');
dockSays.className = 'sr-only'; dockSays.setAttribute('aria-live', 'polite');
document.body.append(dockSays);
let dockWas = 'resting';
function announceDock() {
  if (dock === dockWas) return;
  dockWas = dock;
  dockSays.textContent = { resting: 'Dock returned to navigation.', filtering: 'Dock showing timeline filters.', searching: 'Dock showing search.' }[dock] || '';
}
