'use strict';
// The strips at the top of Dailies, as the iPhone's DailiesView `topStrips`: quiet bands that
// say something needs the user, without stopping them. Top to bottom: conflicts (conflicts.js
// fills that one), no Privacy phrase, reminders silenced, a sync error, and Takes sync skipped.
// Each is a full-width band with the conflict strip's geometry; only the icon, words and tint
// differ. The iPhone's other two: a lapsed subscription can't happen on the Mac, which sells
// nothing; a failed save keeps the Mac's dialog (bridge.js), which says what to do and doesn't
// go by itself (owner, 2026-11-20).
// Loaded before conflicts.js, which puts its strip first.

const stripsBox = document.createElement('div');
stripsBox.id = 'strips';
$('#sidebar').insertBefore(stripsBox, $('#pinned'));

// How long a strip stays before it goes by itself (the iPhone's: sync 8 s). The others stay
// until dismissed.
const STRIP_TIMEOUT = { sync: 8000 };

const STRIP_ICON = {
  conflict: '<path d="M5 12a7 7 0 0 1 12-5l2 2M19 12a7 7 0 0 1-12 5l-2-2M19 4v5h-5M5 20v-5h5"/>',
  phrase: '<circle cx="8" cy="15" r="3.5"/><path d="M10.5 12.5L18 5M15 8l2 2M4 4l16 16"/>',
  silenced: '<path d="M6 16V11a6 6 0 0 1 9.5-4.9M18 11v5l1.5 2h-15M10 20.5h4M4 4l16 16"/>',
  error: '<circle cx="12" cy="12" r="8.5"/><path d="M12 7.5v5.5M12 16v.5"/>',
  quarantine: '<rect x="5.5" y="10.5" width="13" height="10" rx="2"/><path d="M8.5 10.5V8a3.5 3.5 0 0 1 6.6-1.6M4 4l16 16"/>',
};
const stripIcon = name => `<svg class="strip-icon" viewBox="0 0 24 24" aria-hidden="true">${STRIP_ICON[name]}</svg>`;
// The band's inside: icon, words, then its actions.
const stripInner = (icon, text, actions) => `${stripIcon(icon)}<span class="strip-text">${esc(text)}</span>${actions}`;
const stripDismiss = `<button class="strip-act" type="button" data-strip-act="dismiss">${t('Dismiss')}</button>`;

function makeStrip(name, tint) {
  const el = document.createElement('div');
  el.className = `strip strip-${tint}`;
  el.dataset.strip = name;
  el.hidden = true;
  stripsBox.append(el);
  return el;
}

// A strip comes in over 0.2 s while the list below moves to make room (DailiesView animates
// each strip's condition, easeInOut 0.2). Going, it is hidden at once and a copy of it folds
// away. With Reduce Motion it only fades, and the list takes its new place at once.
function stripFold(el, coming) {
  if (still.matches) {
    if (!coming) { el.style.position = 'absolute'; el.style.width = el.offsetWidth + 'px'; }   // out of the flow: nothing below moves
    el.animate(coming ? [{ opacity: 0 }, { opacity: 1 }] : [{ opacity: 1 }, { opacity: 0 }], MOTION.reduced).finished
      .then(() => { if (!coming) el.remove(); }, () => { if (!coming) el.remove(); });
    return;
  }
  const cs = getComputedStyle(el), full = { opacity: 1, height: cs.height, minHeight: cs.minHeight, marginBottom: cs.marginBottom, paddingTop: cs.paddingTop, paddingBottom: cs.paddingBottom, borderTopWidth: cs.borderTopWidth, borderBottomWidth: cs.borderBottomWidth };
  const none = { opacity: 0, height: '0px', minHeight: '0px', marginBottom: '0px', paddingTop: '0px', paddingBottom: '0px', borderTopWidth: '0px', borderBottomWidth: '0px' };
  el.style.overflow = 'hidden';
  const run = el.animate(coming ? [none, full] : [full, none], MOTION.mode);
  run.finished.then(() => { el.style.overflow = ''; if (!coming) el.remove(); }, () => { if (!coming) el.remove(); });
}
// A copy that folds away where the strip was, so the strip itself can go at once.
function stripLeaves(el, leavingClass = 'strip-leaving') {
  const ghost = el.cloneNode(true);
  const look = [...el.classList].filter(c => c.startsWith('strip-')).join(' ');
  ghost.className = `strip-ghost ${look} ${leavingClass}`;   // never .strip or the strip's own class, which still name the strip
  delete ghost.dataset.strip;
  ghost.setAttribute('aria-hidden', 'true'); ghost.inert = true;
  el.before(ghost);
  stripFold(ghost, false);
}
// Show `html` in the strip, or take it away when `html` is null.
function setStrip(el, html, leavingClass) {
  const was = !el.hidden;
  if (html == null) {
    if (was) { stripLeaves(el, leavingClass); el.hidden = true; el.innerHTML = ''; el.stripHTML = ''; }
    return;
  }
  if (el.stripHTML !== html) { el.innerHTML = html; el.stripHTML = html; }   // unchanged, it keeps a focused button
  el.hidden = false;
  if (!was) stripFold(el, true);
}

// ---------- no Privacy phrase ----------
// This Mac holds the key but no Privacy phrase (the shell checks, without a prompt), so its
// Takes can't be recovered anywhere else. The app works, which is why it would go unnoticed.
// Export is the only way out today, and it is behind a question: the file is readable text,
// and it is not a Privacy phrase.
const phraseStrip = makeStrip('phrase', 'ruby strip-phrase');
let phraseMissing = !!window.catchlightLibrary?.phraseMissing;
// A restore (first run, or Settings > Second device) succeeds only once its phrase is stored
// (Vault.createAccount throws otherwise), and the page takes the account it opens without a
// reload (first-run.js, adoptLibrary), so the phrase is there.
function phraseRestored() { phraseMissing = false; paintStrips(); }
function exportReadable() {
  ask(t('Export a readable copy?'), t('The file is readable text and it does not contain a Privacy phrase. Use Start over and Import from a file to re-import your Takes. Delete the export once your Takes are back.'),
    [[t('Export anyway'), () => exportLibrary()], [t('Cancel'), null, 'cancel']]);
}

// A lasting condition goes into Notice History once when it begins, not at each launch; when it
// ends that is forgotten, so a return is recorded again (NoticeOnset). Both are storage notices.
function onset(key, active, message) {
  const k = 'onset.' + key;
  if (!active) { if (store.get(k, false)) store.set(k, false); return; }
  if (store.get(k, false)) return;
  store.set(k, true);
  notice(message, 'storage');
}

// ---------- reminders silenced ----------
// Notifications are off for Catchlight while a Take has a reminder set to alert, so that reminder
// will never show (ReminderScheduler.remindersSilenced: only a denied permission counts; before
// the user is asked, setting a reminder is what asks). Turn on asks the shell, which opens
// System Settings for a denied permission. Closed with its ×, it stays closed for good.
const silencedStrip = makeStrip('silenced', 'add');
let stripNotifications = null;   // the shell's answer: 'enabled', 'denied' or 'ask'
const anyAlertingReminder = () => (typeof takes !== 'undefined' ? takes : []).some(x => x.reminder && x.reminder.notify !== false && !x.reminder.done);
function readStripNotifications() {
  const shell = window.catchlightBridge?.shell;
  if (!shell?.notificationStatus) return;
  shell.notificationStatus().then(status => { stripNotifications = status; paintStrips(); })
    .catch(e => console.error('Reading the notification permission failed', e));
}
addEventListener('focus', readStripNotifications);
addEventListener('load', readStripNotifications);

// ---------- sync error ----------
// The iPhone's words for a failed pass (SyncService.notice), also kept in Notice History. Goes
// by itself after 8 s, longer than a storage note because the user has less context for it.
const syncStrip = makeStrip('sync', 'ruby');
let syncError = null, syncErrorTimer = 0;
function stripSyncError(message) {
  syncError = message;
  clearTimeout(syncErrorTimer);
  syncErrorTimer = setTimeout(() => { if (syncError === message) { syncError = null; paintStrips(); } }, STRIP_TIMEOUT.sync);
  paintStrips();
}

// ---------- Takes skipped by sync ----------
// Takes whose cloud copy failed its check, counted once each however many passes report them
// (AppModel.reportQuarantined), until dismissed. Only a count: never which Takes.
const quarantineStrip = makeStrip('quarantine', 'ruby');
const quarantinedIDs = new Set();
function stripQuarantined(ids) {
  for (const id of ids || []) quarantinedIDs.add(String(id).toLowerCase());
  paintStrips();
}

// A locked page knows nothing of the account (no phrase state, no Takes): that is no reason to
// think a lasting condition has ended, so its onsets are left as they were.
const libraryLocked = () => !!window.catchlightLibrary?.locked;
function paintStrips() {
  if (!libraryLocked()) onset('phraseMissing', phraseMissing, t('No Privacy phrase on this device. Export now, then Settings > Start over.'));
  setStrip(phraseStrip, phraseMissing ? stripInner('phrase', t('No Privacy phrase on this device. Export now, then Settings > Start over.'),
    `<button class="strip-act" type="button" data-strip-act="export" aria-label="${esc(t('Export your Takes'))}" aria-describedby="strip-export-hint">${t('Export now')}</button>`
    + `<span class="sr-only" id="strip-export-hint">${t('Saves a readable copy. Not a Privacy phrase.')}</span>`) : null);
  const muted = stripNotifications === 'denied' && anyAlertingReminder();
  if (stripNotifications != null && !libraryLocked()) onset('remindersSilenced', muted, t('Enable Notifications'));
  const silenced = muted && !store.get('remindersSilencedDismissed', false);
  const hint = 'strip-turn-on-hint';
  setStrip(silencedStrip, silenced ? stripInner('silenced', t('Enable Notifications'),
    `<button class="strip-act" type="button" data-strip-act="turn-on" aria-label="${esc(t('Turn on notifications'))}" aria-describedby="${hint}">${t('Turn on')}</button>`
    + `<span class="sr-only" id="${hint}">${t('Opens System Settings.')}</span>`
    + `<button class="strip-x" type="button" data-strip-act="close" aria-label="${esc(t('Dismiss'))}"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M7 7l10 10M17 7L7 17"/></svg></button>`) : null);
  setStrip(syncStrip, syncError ? stripInner('error', syncError, stripDismiss) : null);
  setStrip(quarantineStrip, quarantinedIDs.size ? stripInner('quarantine', t("%lld Takes couldn't be verified and were skipped.", quarantinedIDs.size), stripDismiss) : null);
}

stripsBox.addEventListener('click', e => {
  const act = e.target.closest('[data-strip-act]')?.dataset.stripAct, strip = e.target.closest('[data-strip]')?.dataset.strip;
  if (!act) return;
  if (act === 'export') exportReadable();
  else if (act === 'turn-on') window.catchlightBridge?.shell.enableNotifications?.()?.catch(e => console.error('Asking for notification permission failed', e));
  else if (act === 'close') { store.set('remindersSilencedDismissed', true); paintStrips(); }
  else if (act === 'dismiss' && strip === 'sync') { syncError = null; clearTimeout(syncErrorTimer); paintStrips(); }
  else if (act === 'dismiss' && strip === 'quarantine') { quarantinedIDs.clear(); paintStrips(); }
});

paintStrips();   // the strips known at load (takes.js repaints them with every render after this)
