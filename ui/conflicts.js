'use strict';
// Sync conflicts (M3): a Take changed on two devices since the last sync, or edited here while a
// sync changed it. As the iPhone's DailiesView banner and ConflictResolutionView: a banner in
// Dailies says how many, and Review opens both versions side by side. The user keeps this Mac's
// version (Local), the other device's (Cloud), or both (owner, 2026-10-05); Skip for now leaves
// it waiting. Until a choice the item is held (owner, 2026-10-07): read-only on the page (app.js,
// held), refused by the shell's saves, and never uploaded by sync. The shell keeps the waiting
// pairs (ConflictQueue, sealed on disk), so in a plain browser there are none and nothing here shows.

const conflictBanner = document.createElement('div');
conflictBanner.className = 'conflict-banner';
conflictBanner.hidden = true;
$('#sidebar').insertBefore(conflictBanner, $('#pinned'));

const conflictSheet = document.createElement('dialog');
conflictSheet.className = 'conflicts';
conflictSheet.setAttribute('aria-labelledby', 'conflicts-heading');
document.body.append(conflictSheet);

let conflictList = [];
const conflictChoice = {};              // id → 'local' | 'remote', picked but not yet kept
const conflictSkipped = new Set();     // Skip for now: hidden until the next launch or sync finds it again
const conflictSeen = {};               // id → the versions a pick was made against
const conflictDamagedNoticed = new Set();   // damaged conflicts already in Notice History this launch

// A Script's blocks are its markdown lines; a Take's are text and checklist items.
const conflictText = t => t.kind === 'script'
  ? (t.blocks || []).join('\n').trim() || L10N.t('Untitled Script')
  : (t.blocks || []).map(b => (b.k === 'check' ? (b.done ? '☑ ' : '☐ ') : '') + b.text).join('\n').trim() || L10N.t('Untitled Take');
// What the waiting pairs are, in words: Takes, Scripts, or Takes and Scripts. A pair counts as a
// Script when either side is one (a Take made a Script here, edited as a Take elsewhere).
const isScriptPair = c => c.local?.kind === 'script' || c.remote?.kind === 'script';
// Which of Takes, Scripts or both the pairs are, so each sentence can be whole for each.
const conflictKinds = list => {
  const scripts = list.filter(isScriptPair).length, takes = list.length - scripts;
  return scripts && takes ? 'both' : scripts ? 'scripts' : 'takes';
};
const conflictWhen = t => {
  const ms = t.modifiedAt ?? Date.parse(t.at);
  return Number.isFinite(ms) ? new Date(ms).toLocaleString(L10N.dateLocale(undefined), { dateStyle: 'medium', timeStyle: 'short' }) : '';
};

async function loadConflicts() {
  if (!window.catchlightBridge?.conflicts) return;
  let all;
  try { all = await catchlightBridge.conflicts(); }
  catch (e) { console.error('Reading the conflicts failed', e); return; }
  // A conflict that doesn't open has no versions to choose between, but its Take stays held,
  // and the user is told once a launch.
  conflictList = all.filter(c => !c.damaged);
  for (const c of all) if (c.damaged && !conflictDamagedNoticed.has(c.id)) {
    conflictDamagedNoticed.add(c.id);
    if (typeof notice === 'function') notice(t("A waiting conflict couldn't be opened, so its Take stays as it is and isn't synced. Report it so it can be looked at."), 'conflict');
  }
  setHeld(all);   // skipped ones too: they still wait for the choice
  // A pair the next sync found again is waiting again.
  for (const id of [...conflictSkipped]) if (!conflictList.some(c => c.id === id)) conflictSkipped.delete(id);
  // A pick only stands for the versions it was made against: if a sync replaced either side,
  // the user chooses again.
  for (const c of conflictList) {
    const sig = JSON.stringify([c.local, c.remote]);
    if (conflictSeen[c.id] !== sig) { delete conflictChoice[c.id]; conflictSeen[c.id] = sig; }
  }
  paintConflicts();
}

const shownConflicts = () => conflictList.filter(c => !conflictSkipped.has(c.id));

function paintConflicts() {
  const n = conflictList.length;
  conflictBanner.hidden = n === 0;
  const kinds = conflictKinds(conflictList);
  const said = kinds === 'both' ? t('%lld Takes and Scripts changed on another device.', n)
    : kinds === 'scripts' ? t('%lld Scripts changed on another device.', n) : t('%lld Takes changed on another device.', n);
  conflictBanner.innerHTML = n ? `<span>${esc(said)}</span><button class="slink" type="button" data-cf="review">${t('Review')}</button>` : '';
  if (conflictSheet.open) paintConflictSheet();
}

function paintConflictSheet() {
  const list = shownConflicts();
  if (!list.length) {
    // As the iPhone: a moment of "All caught up." rather than the sheet snapping shut.
    conflictSheet.innerHTML = `<p class="cf-done" role="status">${t('All caught up.')}</p>`;
    setTimeout(() => { if (!shownConflicts().length) conflictSheet.close(); }, 900);
    return;
  }
  const panel = (c, side) => {
    const t = c[side], picked = conflictChoice[c.id] === side;
    return `<button class="cf-version${picked ? ' picked' : ''}" type="button" data-cf="pick" data-id="${esc(c.id)}" data-side="${side}" aria-pressed="${picked}">
      <span class="cf-label">${side === 'local' ? L10N.t('Local') : L10N.t('Cloud')}${isScriptPair(c) ? ` · ${t.kind === 'script' ? L10N.t('Script') : L10N.t('Take')}` : ''}</span>
      <span class="cf-when">${esc(conflictWhen(t))}</span>
      <span class="cf-body">${esc(conflictText(t))}</span>
    </button>`;
  };
  const kinds = conflictKinds(list);
  conflictSheet.innerHTML = `<h2 id="conflicts-heading">${t('Sync conflicts')}</h2>
    <p class="cf-guide">${kinds === 'both' ? t("These Takes and Scripts were edited on different devices, so we can't tell which to keep. Choose the version you'd like to keep, or keep both. A version you don't keep is removed.")
      : kinds === 'scripts' ? t("These Scripts were edited on different devices, so we can't tell which to keep. Choose the version you'd like to keep, or keep both. A version you don't keep is removed.")
      : t("These Takes were edited on different devices, so we can't tell which to keep. Choose the version you'd like to keep, or keep both. A version you don't keep is removed.")}</p>
    ${list.map(c => `<section class="cf-item" data-id="${esc(c.id)}">
      <div class="cf-pair">${panel(c, 'local')}${panel(c, 'remote')}</div>
      <div class="cf-actions">
        <button class="fr-pill primary" type="button" data-cf="keep" data-id="${esc(c.id)}"${conflictChoice[c.id] ? '' : ' disabled'}>${t('Keep this version')}</button>
        <button class="fr-pill" type="button" data-cf="both" data-id="${esc(c.id)}">${t('Keep both')}</button>
        <button class="slink" type="button" data-cf="skip" data-id="${esc(c.id)}">${t('Skip for now')}</button>
      </div>
    </section>`).join('')}
    <div class="cf-close"><button class="slink" type="button" data-cf="close">${t('Close')}</button></div>`;
}

function openConflicts() {
  paintConflictSheet();
  conflictSheet.showModal();
  conflictSheet.querySelector('.cf-version')?.focus();
}

async function resolveConflict(id, choice) {
  // The choice names the pair it was made against: if a sync replaced it meanwhile, the shell
  // refuses, and the user chooses again between the versions now waiting.
  const revision = conflictList.find(c => c.id === id)?.revision ?? '';
  try {
    await catchlightBridge.resolveConflict(id, choice, revision);
  } catch (e) {
    // Only this means the choice wasn't written: the store is as it was. The shell's message is
    // English on purpose (ConflictQueue), so this test holds in every language.
    console.error('Saving a conflict choice failed', e);
    if (/changed while you were choosing/.test(String(e?.message ?? e)))
      ask(t('The versions changed'), t('This changed again on another device while you were choosing. Look at both versions again, then choose.'), [[t('OK'), null, 'cancel']]);
    else ask(t("Your choice wasn't saved"), t('Both versions are still there. Try again, and if it keeps happening, report it with this detail: %@', String(e?.message ?? e)), [[t('OK'), null, 'cancel']]);
    return loadConflicts();
  }
  delete conflictChoice[id];
  // The choice is written. Show it, and send it to the other devices; a failure in either is
  // logged, and the next refresh or sync catches up.
  await catchlightBridge.refresh().catch(e => console.error('Refreshing the Takes failed', e));
  catchlightBridge.sync?.('save').catch?.(e => console.error('Sync after a conflict choice failed', e));
  await loadConflicts();
}

conflictBanner.addEventListener('click', e => { if (e.target.closest('[data-cf="review"]')) openConflicts(); });
conflictSheet.addEventListener('click', e => {
  const b = e.target.closest('[data-cf]');
  if (!b) return;
  const id = b.dataset.id;
  switch (b.dataset.cf) {
    case 'pick': conflictChoice[id] = b.dataset.side; paintConflictSheet(); break;
    case 'keep': if (conflictChoice[id]) resolveConflict(id, conflictChoice[id]); break;
    case 'both': resolveConflict(id, 'both'); break;
    case 'skip': conflictSkipped.add(id); paintConflictSheet(); break;
    case 'close': conflictSheet.close(); break;
  }
});

addEventListener('load', loadConflicts);
