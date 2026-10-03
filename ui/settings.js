'use strict';
// Settings, as the iPhone's SettingsView (As-Built, D-274): one sheet of grouped sections,
// every choice a dropdown showing its value on the right, sub-screens as sheets over it.
// The desktop gives each pane its own section (owner, 2026-10-02): Dailies, the Script
// timeline and the Script area. Loaded after app.js and before takes.js, which reads
// `settings` on its first render. Opens with ⌘, (the shells add the menu item), the
// Scripts dock's view button, or a swipe up on the Dailies dock as on iOS.

const settings = Object.assign({
  takeSpacing: 'standard', takePreview: 'some', takeSort: 'oldest', takeArrangement: 'date', creationStamp: 'off',
  scriptTextSize: 'standard', newScriptPage: 'region', spellcheck: 'on',
  spotlight: 'none', writingTools: 'off',   // both private until the user opts in (D-110, D-246)
  reminderHours: '24', snooze: '60', followUp: true,
  lockAfter: '60', autoDelete: 'never', confirmDelete: true,
  notifications: 'ask', syncMode: 'automatic', notices: [],
}, store.get('settings', {}));
const saveSettings = () => store.set('settings', settings);

const createdLabel = iso => {
  const d = new Date(iso);
  return `Created on ${d.toLocaleDateString([], { year: 'numeric', month: '2-digit', day: '2-digit' })} at ${d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}`;
};

// What the Script area reads.
const SCRIPT_TEXT = { small: '14px', standard: '16px', large: '19px' };
function applyScriptArea() {
  doc.style.setProperty('--doc-size', SCRIPT_TEXT[settings.scriptTextSize]);
  doc.spellcheck = settings.spellcheck === 'on';
}
const newScriptMode = () => settings.newScriptPage === 'region' ? regionPaper() : settings.newScriptPage;

// ---------- the rows ----------
const SI = {   // row icons, drawn to sit beside the iOS SF Symbols they stand in for
  mode: '<circle cx="12" cy="12" r="8"/><path d="M12 4a8 8 0 0 1 0 16z" fill="currentColor"/>',
  palette: '<path d="M12 4a8 8 0 1 0 0 16c1.2 0 1.6-1 1-2s0-2 1.5-2H17a3 3 0 0 0 3-3c0-5-3.6-9-8-9z"/><circle cx="8.5" cy="11" r="1"/><circle cx="12" cy="8" r="1"/><circle cx="15.5" cy="11" r="1"/>',
  spacing: '<path d="M12 3v4M10 5l2-2 2 2M12 21v-4M10 19l2 2 2-2M5 10h14M5 14h14"/>',
  preview: '<path d="M5 7h14M5 11h10M5 15h14M5 19h8"/>',
  order: '<path d="M8 5v14M5 16l3 3 3-3M16 19V5M13 8l3-3 3 3"/>',
  hand: '<path d="M9 12V6a1.5 1.5 0 0 1 3 0v5M12 11V5a1.5 1.5 0 0 1 3 0v6M15 11V7a1.5 1.5 0 0 1 3 0v6c0 4-2.5 7-6 7-2.5 0-4-1.5-5.5-4L5 13a1.4 1.4 0 0 1 2.2-1.7L9 13"/>',
  calendar: '<rect x="4" y="6" width="16" height="14" rx="2"/><path d="M4 10h16M8 4v4M16 4v4"/>',
  textsize: '<path d="M4 18l4-11 4 11M5.5 14h5M14 18l3-8 3 8M15 15.5h4"/>',
  page: '<path d="M7 3h7l4 4v14H7z"/><path d="M14 3v4h4"/>',
  spell: '<path d="M4 15l3-9 3 9M5 12h4M13 6h3.5a2 2 0 0 1 0 4H13zM13 10h4a2 2 0 0 1 0 4h-4zM5 19l2 2 4-4"/>',
  clock: '<circle cx="12" cy="12" r="8"/><path d="M12 8v4l3 2"/>',
  zzz: '<path d="M5 6h5l-5 6h5M13 11h4l-4 5h4M17 4h3l-3 3h3"/>',
  bell: '<path d="M6 16V11a6 6 0 0 1 12 0v5l1.5 2h-15zM10 20.5h4"/>',
  lock: '<rect x="5.5" y="10.5" width="13" height="10" rx="2"/><path d="M8.5 10.5V8a3.5 3.5 0 0 1 7 0v2.5"/>',
  trash: '<path d="M5 7h14M10 7V5h4v2M7 7l1 13h8l1-13"/>',
  warn: '<path d="M12 4l9 16H3z"/><path d="M12 10v4M12 17v.5"/>',
  key: '<circle cx="8" cy="12" r="3.5"/><path d="M11.5 12H20M17 12v3M20 12v2"/>',
  device: '<rect x="3" y="5" width="12" height="9" rx="1.5"/><path d="M6 17h6M17 9h3v10h-3zM9 14v3"/>',
  cloud: '<path d="M7 18h10a4 4 0 0 0 .5-8 6 6 0 0 0-11.4 1.5A3.3 3.3 0 0 0 7 18z"/>',
  export: '<path d="M12 15V4M8 8l4-4 4 4M5 13v7h14v-7"/>',
  import: '<path d="M12 4v11M8 11l4 4 4-4M5 13v7h14v-7"/>',
  file: '<path d="M7 3h7l4 4v14H7z"/><path d="M14 3v4h4M12.5 11v6M9.5 14h6"/>',
  info: '<circle cx="12" cy="12" r="8"/><path d="M12 11v5M12 8v.5"/>',
  restart: '<path d="M5 12a7 7 0 1 0 2-5M5 4v4h4"/>',
  bug: '<rect x="8" y="8" width="8" height="11" rx="4"/><path d="M12 8v11M9 6l1.5 2M15 6l-1.5 2M4 12h4M16 12h4M5 17l3-1M19 17l-3-1"/>',
  list: '<rect x="4" y="5" width="16" height="14" rx="2"/><path d="M8 9h8M8 12h8M8 15h5"/>',
  search: '<circle cx="10.5" cy="10.5" r="6"/><path d="M15 15l5 5"/>',
  wand: '<path d="M4 20L15 9M13 7l4 4M17 3v3M15.5 4.5h3M20 9v2M19 10h2"/>',
};
const icon = k => `<svg class="srow-icon" viewBox="0 0 24 24" aria-hidden="true">${SI[k]}</svg>`;
const CHEV = '<svg class="srow-chev" viewBox="0 0 24 24" aria-hidden="true"><path d="M10 7l5 5-5 5"/></svg>';
const UPDOWN = '<svg class="srow-chev" viewBox="0 0 24 24" aria-hidden="true"><path d="M8.5 9.5L12 6l3.5 3.5M8.5 14.5L12 18l3.5-3.5"/></svg>';

// A picker: the whole row is a native select, so it opens the platform's own menu with a
// check beside the current value, as iOS's Menu does, on every shell and on touch.
// An option can be [value, label, locked]: shown, greyed and not selectable, as iOS's Menu
// disables one. A note sits under the label, as iOS puts a caption in the same cell.
function pick(id, ic, label, options, get, note = '') {
  const cur = options.find(o => o[0] === get());
  return `<label class="srow${note ? ' tall' : ''}">${icon(ic)}<span class="srow-label">${label}${note ? `<small>${note}</small>` : ''}</span><span class="srow-value">${cur ? cur[1] : ''}</span>${UPDOWN}
    <select data-set="${id}" aria-label="${label}">${options.map(([v, l, locked]) => `<option value="${v}"${v === get() ? ' selected' : ''}${locked ? ' disabled' : ''}>${l}</option>`).join('')}</select></label>`;
}
const toggle = (id, ic, label, sub, on) => `<label class="srow tall">${icon(ic)}<span class="srow-label">${label}<small>${sub}</small></span>
  <input type="checkbox" role="switch" class="srow-switch" data-set="${id}"${on ? ' checked' : ''}></label>`;
const link = (id, ic, label, value = '', chev = true, cls = '') => `<button class="srow${cls}" type="button" data-open="${id}">${icon(ic)}<span class="srow-label">${label}</span><span class="srow-value">${value}</span>${chev ? CHEV : ''}</button>`;
const group = (head, rows, foot = '') => `<h3 class="sgroup-head">${head}</h3><div class="sgroup">${rows.join('')}</div>${foot ? `<p class="sgroup-foot">${foot}</p>` : ''}`;

const SPACING = [['compact', 'Compact'], ['standard', 'Standard'], ['comfort', 'Comfort']];
const PREVIEW = [['single', 'Single'], ['some', 'Some'], ['all', 'All']];
const ORDER = [['oldest', 'Oldest first'], ['newest', 'Newest first']];

function settingsPage() {
  const folder = store.get('account', {})?.folder;
  const notif = settings.notifications === 'enabled' ? '<i class="sdot ok"></i>Enabled' : 'Enable';
  return `<h2 class="page-heading">Settings</h2>
  ${group('Appearance', [
    pick('mode', 'mode', 'Mode', [['auto', 'System'], ['daylight', 'Light'], ['night', 'Dark']], () => scene),
    `<div class="srow off">${icon('palette')}<span class="srow-label">Scenes</span><span class="srow-value">Coming soon</span></div>`,
  ])}
  ${group('Dailies', [
    pick('takeSpacing', 'spacing', 'View', SPACING, () => settings.takeSpacing),
    pick('takePreview', 'preview', 'Preview', PREVIEW, () => settings.takePreview),
    pick('takeSort', 'order', 'Order', ORDER, () => settings.takeSort),
    pick('takeArrangement', 'hand', 'Arrangement', [['date', 'Date'], ['manual', 'Manual']], () => settings.takeArrangement),
    pick('creationStamp', 'calendar', 'Creation date', [['off', 'Off'], ['editor', 'Editor only'], ['always', 'Always']], () => settings.creationStamp),
  ])}
  ${group('Script timeline', [
    pick('scriptSpacing', 'spacing', 'View', SPACING, () => view.spacing),
    pick('scriptPreview', 'preview', 'Preview', PREVIEW, () => view.preview),
    pick('scriptSort', 'order', 'Order', ORDER, () => view.sort),
  ])}
  ${group('Script area', [
    pick('scriptTextSize', 'textsize', 'Text size', [['small', 'Small'], ['standard', 'Standard'], ['large', 'Large']], () => settings.scriptTextSize),
    pick('newScriptPage', 'page', 'New Scripts', [['region', `Region (${regionPaper() === 'a4' ? 'A4' : 'US Letter'})`], ['continuous', 'Continuous'], ['a4', 'A4'], ['letter', 'US Letter']], () => settings.newScriptPage),
    pick('spellcheck', 'spell', 'Spelling', [['on', 'Check as I type'], ['off', 'Off']], () => settings.spellcheck),
  ])}
  ${group('Reminders', [
    pick('reminderHours', 'clock', 'Default timing', [['1', '1 hour'], ['6', '6 hours'], ['12', '12 hours'], ['24', '1 day'], ['48', '2 days']], () => settings.reminderHours),
    pick('snooze', 'zzz', 'Snooze Duration', [['5', '5 mins'], ['15', '15 mins'], ['30', '30 mins'], ['60', '1 hour'], ['360', '6 hours'], ['720', '12 hours'], ['1440', '24 hours']], () => settings.snooze),
    toggle('followUp', 'bell', 'Follow-up reminders', 'Re-nudge until you mark it done', settings.followUp),
  ])}
  ${group('Security', [
    pick('lockAfter', 'lock', 'Lock after', [['30', '30 seconds'], ['60', '1 minute'], ['300', '5 minutes'], ['1800', '30 minutes'], ['3600', '1 hour']], () => settings.lockAfter),
    pick('autoDelete', 'trash', 'Auto-Delete (exc. notes)', [['never', 'Never'], ['daily', 'Daily'], ['weekly', 'Weekly'], ['monthly', 'Monthly'], ['annually', 'Annually']], () => settings.autoDelete),
    toggle('confirmDelete', 'warn', 'Confirm before deleting', 'A deleted Take cannot be recovered', settings.confirmDelete),
    link('phrase', 'key', 'Privacy phrase'),
    link('second-device', 'device', 'Second device'),
    // How much of each Take the OS search may index (SpotlightExposure, D-110). Past the type
    // label it puts decrypted text in the OS index; the two text levels stay locked, as on
    // iOS, until the platform's search can find them.
    pick('spotlight', 'search', PLATFORM.search, [['none', 'None'], ['type', 'Type only'], ['firstLine', 'Type + first line', true], ['all', 'Type + full text', true]],
      () => settings.spotlight, 'On-device search only. Considus can never read your Takes. Text levels are greyed out until search can find them.'),
    // Writing Tools (D-246) is Apple's, so only the Mac has the row. Off by default: the
    // editor would otherwise inherit it, and either mode sends that Take to Apple.
    PLATFORM.writingTools ? pick('writingTools', 'wand', 'Writing Tools', [['off', 'Off'], ['panel', 'Panel'], ['inline', 'Inline']],
      () => settings.writingTools, 'Panel suggests, you accept. Inline rewrites in place. Both send that Take to Apple. Your Privacy phrase never goes.') : '',
  ])}
  ${group('System', [
    link('notifications', 'bell', 'Notifications', notif, settings.notifications !== 'enabled'),
    link('cloud', 'cloud', 'Cloud Storage', folder ? esc(folder.split('/').pop()) : 'Not configured'),
    link('export', 'export', 'Export Takes', '', false),
    folder ? link('import-notes', 'import', 'Import notes', '', false) : '',
    link('import-file', 'file', 'Import from a file', '', false),
    link('about', 'info', 'About', 'Catchlight 0.1 (prototype)'),
    link('start-over', 'restart', 'Start over', '', false, ' danger'),
  ], 'Erases every Take here and creates a new Privacy phrase. Cloud copies become unreadable too. Export first, it is the only way back.')}
  ${group('Support', [
    link('report', 'bug', 'Report an issue', '', false),
    link('notices', 'list', 'Notice History'),
    link('diagnostics', 'export', 'Export diagnostics', '', false),
  ])}`;
}

// ---------- sub-screens ----------
const SUB = {
  cloud: () => {
    const folder = store.get('account', {})?.folder;
    const modes = { automatic: 'Syncs automatically in the background and when you open the app.', manual: 'Only syncs when you click Sync Now.', disabled: `Never syncs. Your Takes stay on this ${PLATFORM.device}.` };
    return ['Cloud Storage', `<div class="ssub-col">
      <h2 class="ssub-heading">Choose a cloud folder you own</h2>
      <p>Select an empty folder, or create a new one, and we'll take care of the rest.</p>
      <p class="quiet">Catchlight never sees your files. Only you can read them.</p>
      ${folder ? `<p class="sfolder">✓ ${esc(folder)}</p>` : ''}
      <button class="fr-pill primary" type="button" data-act="pick-folder">Choose folder</button>
      ${folder ? '<button class="slink danger" type="button" data-act="remove-folder">Remove</button>' : ''}
      <p class="sfine">Tested with iCloud Drive, Dropbox, Internxt, Koofr and Filen. Others may work. You'll need the provider's app installed and signed in.</p>
      <hr>
      <div class="sgroup">${pick('syncMode', 'cloud', 'Sync', [['automatic', 'Automatic'], ['manual', 'Manual'], ['disabled', 'Disabled']], () => settings.syncMode)}</div>
      <p class="quiet">${modes[settings.syncMode]}</p>
      ${settings.syncMode === 'manual' ? `<button class="slink" type="button" data-act="sync-now"${folder ? '' : ' disabled'}>Sync Now</button>` : ''}
    </div>`];
  },
  about: () => ['About', `<div class="ssub-col">
      <div class="fr-brand" aria-hidden="true"><span class="fr-iris">${iris(['note', 'task', 'remind', 'important'])}</span><span class="fr-wordmark">Catchlight</span></div>
      <h2 class="ssub-heading">Privacy-first notes and reminders</h2>
      <p class="quiet sversion" tabindex="0" data-copy-info title="Right-click to copy version and device info">Version 0.1 (prototype)</p>
      <div class="scard"><h4>Open source licences</h4>
        <p>Cormorant Garamond and DM Sans, under the SIL Open Font License 1.1. The licence text for each is beside the fonts and listed in NOTICE.</p></div>
      <div class="scard links">${[['Privacy Policy', 'https://catchlight.app/privacy/'], ['Terms of Service', 'https://catchlight.app/terms/'], ['Support', 'https://catchlight.app/support/?platform=macOS'], ['Website', 'https://catchlight.app']]
        .map(([l, u]) => `<a href="${u}" target="_blank" rel="noopener">${l}<span aria-hidden="true">↗</span></a>`).join('')}</div>
      <p class="quiet small">Made by Considus</p></div>`],
  phrase: () => ['Privacy phrase', `<div class="ssub-col">
      <h2 class="ssub-heading">Reveal your Privacy phrase</h2>
      <p>Authenticate with Touch ID or your password to view the 12 words. They're the only way to recover your account, so reveal them somewhere private.</p>
      <button class="fr-pill primary" type="button" data-act="reveal-phrase">Reveal phrase</button></div>`],
  'phrase-shown': () => {
    const words = store.get('account', {})?.phrase;
    if (!words) return ['Privacy phrase', `<div class="ssub-col"><h2 class="ssub-heading">Phrase isn't on this device</h2>
      <p>Catchlight stores the Privacy phrase only on the device where you set it up. If you onboarded on a different device, use that one to view it.</p></div>`];
    return ['Privacy phrase', `<div class="ssub-col">
      <ol class="fr-words">${words.map((w, i) => `<li><span>${i + 1}</span><b class="held">${esc(w)}</b></li>`).join('')}</ol>
      <p>Write these 12 words down somewhere safe, on paper. They're the only way back into your Takes on a new device.</p>
      <button class="fr-pill primary hold" type="button" data-hold>Hold to reveal</button></div>`];
  },
  'second-device': () => ['Second device', `<div class="ssub-col">
      <div class="swarn">This replaces the account on this ${PLATFORM.device}. Takes stored only here will be removed and can't be recovered. If you haven't already, close this and use Export Takes (Markdown) to keep a copy first.</div>
      <h2 class="ssub-heading">Enter your Privacy phrase</h2>
      <p>The 12 words from your other device, in order.</p>
      ${phraseGrid()}
      <p class="fr-status" id="sd-status" aria-live="polite">0 of 12 words</p>
      <button class="fr-pill primary" type="button" data-act="sd-restore" disabled>Restore on this device</button></div>`],
  notices: () => ['Notice History', settings.notices.length ? `<div class="sgroup">${settings.notices.map(n => `<div class="srow">${icon('info')}<span class="srow-label">${esc(n)}</span></div>`).join('')}</div>`
    : `<div class="ssub-col empty-col">${icon('bell')}<h2 class="ssub-heading">No notices yet</h2><p class="quiet">Sync, storage and conflict notices will appear here.</p></div>`],
};

// ---------- the sheets ----------
const sheet = $('#settings');
let subStack = [];
function paintSettings(keepScroll = true) {
  const scroll = sheet.querySelector('.sheet-scroll')?.scrollTop || 0;
  const top = subStack.at(-1);
  const [title, body] = top ? SUB[top]() : [null, settingsPage()];
  sheet.innerHTML = `<div class="sheet-panel${top ? ' sub' : ''}" role="dialog" aria-modal="true" aria-label="${title || 'Settings'}">
    <div class="sheet-bar">${top ? `<button class="sheet-back" type="button" data-act="back" aria-label="Back">${CHEV}</button><span class="sheet-title">${title}</span>` : '<span></span>'}
      <button class="sheet-x" type="button" data-act="close" aria-label="Close ${title || 'Settings'}"><svg viewBox="0 0 24 24"><path d="M6.5 6.5l11 11M17.5 6.5l-11 11"/></svg></button></div>
    <div class="sheet-scroll">${body}</div></div>`;
  if (keepScroll) sheet.querySelector('.sheet-scroll').scrollTop = top ? 0 : scroll;
}
function openSettings(section) {
  subStack = [];
  sheet.hidden = false;
  paintSettings(false);
  requestAnimationFrame(() => sheet.classList.add('open'));
  if (section) [...sheet.querySelectorAll('.sgroup-head')].find(h => h.textContent === section)?.scrollIntoView({ block: 'start' });
  sheet.querySelector('.sheet-x').focus();
}
function closeSettings() {
  sheet.classList.remove('open');
  ctx.hidden = true;   // About's menu sits over the sheet
  setTimeout(() => { if (!sheet.classList.contains('open')) { sheet.hidden = true; sheet.innerHTML = ''; } }, still.matches ? 0 : 300);
}
const notice = msg => { settings.notices.unshift(msg); saveSettings(); };

sheet.addEventListener('change', e => {
  const k = e.target.dataset.set;
  if (!k) return;
  const v = e.target.type === 'checkbox' ? e.target.checked : e.target.value;
  if (k === 'mode') { scene = v; store.set('scene', v); applyScene(); }
  else if (k.startsWith('script') && ['scriptSpacing', 'scriptPreview', 'scriptSort'].includes(k)) {
    view[{ scriptSpacing: 'spacing', scriptPreview: 'preview', scriptSort: 'sort' }[k]] = v; store.set('view', view); renderScripts();
  } else {
    settings[k] = v; saveSettings();
    if (k.startsWith('take') || k === 'creationStamp') renderTakes();
    if (k === 'scriptTextSize' || k === 'spellcheck') { applyScriptArea(); paginate(); }
  }
  paintSettings();
  sheet.querySelector(`[data-set="${k}"]`)?.focus();   // the repaint must not lose a keyboard user's place
});

sheet.addEventListener('click', async e => {
  if (e.target === sheet) { closeSettings(); return; }   // the dimmed window behind the sheet
  const open = e.target.closest('[data-open]')?.dataset.open, act = e.target.closest('[data-act]')?.dataset.act;
  if (act === 'close') closeSettings();
  else if (act === 'back') { subStack.pop(); paintSettings(); }
  else if (act === 'pick-folder') { store.set('account', { ...store.get('account', {}), folder: shell.chooseFolder() }); paintSettings(); }
  else if (act === 'remove-folder') { store.set('account', { ...store.get('account', {}), folder: null }); paintSettings(); }
  else if (act === 'sync-now') { e.target.textContent = 'Syncing…'; e.target.disabled = true; setTimeout(() => paintSettings(), 2000); }
  else if (act === 'sd-restore') secondDeviceRestore();
  else if (act === 'reveal-phrase') { subStack.push('phrase-shown'); paintSettings(); }
  else if (open && SUB[open]) {
    const go = () => { subStack.push(open); paintSettings(); if (open === 'second-device') sheet.querySelector('[data-word="0"]').focus(); };
    if (open !== 'second-device') go();
    else ask('Add this device to your account?', 'Enter your Privacy phrase to bring your Takes onto this device. Any Takes stored only on this device will be removed. To keep a copy first, cancel and use Export Takes (Markdown), or make sure they\'re already in your cloud folder.',
      [['Cancel', null, 'cancel'], ['Continue', go, 'danger']]);
  }
  else if (open === 'notifications' && settings.notifications !== 'enabled') { settings.notifications = 'enabled'; saveSettings(); paintSettings(); }
  else if (open === 'export') exportTakes(takes);
  else if (open === 'import-notes') ask('Import notes', 'Any items in the folder, that have previously been imported, will be imported again.', [
    ['Proceed', () => { notice('Import notes: the Import folder is read by the shell, which does not exist yet.'); paintSettings(); }], ['Cancel', null, 'cancel']]);
  else if (open === 'import-file') notice('Import from a file: the file picker belongs to the shell, which does not exist yet.');
  else if (open === 'report') window.open('https://catchlight.app/support/?platform=macOS&app=0.1', '_blank', 'noopener');
  else if (open === 'diagnostics') notice('Export diagnostics: the log is written by the shell, which does not exist yet.');
  else if (open === 'start-over') startOver();
  if (open === 'notices' || ['import-file', 'diagnostics'].includes(open)) paintSettings();
});

// Second device: the same entry grid as first run. Core checks the words; here, their shape.
function paintSecondDevice(error) {
  const n = phraseWords(sheet).filter(Boolean).length, status = $('#sd-status');
  status.classList.toggle('error', !!error);
  status.textContent = error || (n === 12 ? 'Ready to restore.' : `${n} of 12 words`);
  sheet.querySelector('[data-act="sd-restore"]').disabled = n < 12;
}
function secondDeviceRestore() {
  if (sheet.querySelector('[data-act="sd-restore"]').disabled) return;
  if (!shell.phraseLooksValid(phraseWords(sheet))) { paintSecondDevice("That doesn't look right. Check the words and try again."); return; }
  // As on iOS, this replaces the account here: Takes stored only on this device go, and so
  // does the phrase kept from first run, which is no longer this account's.
  store.set('account', { ...store.get('account', {}), restored: true, phrase: undefined });
  takes = []; saveTakes(); renderTakes();
  notice('Restored this device from its Privacy phrase.');
  closeSettings();
}
// Wired once first-run.js, which owns the grid, has loaded.
addEventListener('DOMContentLoaded', () => wirePhraseEntry(sheet, () => paintSecondDevice(), secondDeviceRestore));

// Hold to reveal: the words show only while the button is held.
sheet.addEventListener('pointerdown', e => {
  const b = e.target.closest('[data-hold]');
  if (!b) return;
  sheet.classList.add('revealing'); b.textContent = 'Release to hide';
  const end = () => { sheet.classList.remove('revealing'); b.textContent = 'Hold to reveal'; removeEventListener('pointerup', end); removeEventListener('pointercancel', end); };
  addEventListener('pointerup', end); addEventListener('pointercancel', end);
});

// About's version line copies a short, paste-ready support block (AboutView.supportInfoString):
// version, OS and model, and nothing from the user's Takes. Right-click it, or ⇧F10 from the
// keyboard, as VoiceOver's named action on iOS.
const supportInfo = () => `Catchlight 0.1 (prototype)\n${shell.systemInfo()}`;
sheet.addEventListener('keydown', e => {
  const v = e.target.closest('[data-copy-info]');
  if (!v || !(e.key === 'ContextMenu' || (e.shiftKey && e.key === 'F10'))) return;
  e.preventDefault();
  const r = v.getBoundingClientRect();
  if (openCtx(v, r.left + 12, r.bottom)) ctx.querySelector('button')?.focus();
});

// Start over, as on iOS: Export Takes exports and stops there; "Erase. Takes exported" goes on
// to the erase question; Cancel stops everything. After erasing there is nothing left to show,
// so a last screen says so and offers no way back (ResetCompleteView, D-253). Touch ID belongs
// to the shell.
function startOver() {
  ask('Export your Takes?', 'Export Takes now. This is the only way to preserve them. This will make cloud copies unreadable.', [
    ['Export Takes', () => exportTakes(takes)],
    ['Erase. Takes exported', () => ask('Erase everything on this device?', 'This deletes every Take on this device and the Privacy phrase that unlocks them. Takes in your cloud folder will be unreadable. This cannot be undone.',
      [['Cancel', null, 'cancel'], ['Erase everything', eraseEverything, 'danger']]), 'danger'],
    ['Cancel', null, 'cancel'],
  ]);
}
function eraseEverything() {
  Object.keys(localStorage).filter(k => k.startsWith('cl.')).forEach(k => { try { localStorage.removeItem(k); } catch {} });
  closeSettings();
  const done = document.createElement('section');
  done.className = 'reset-done'; done.setAttribute('role', 'alert');
  done.innerHTML = `<h1>Catchlight has been reset</h1><p>Quit Catchlight and open it again to set up a new Privacy phrase. If you exported your Takes, you can bring them back with Import from a file.</p>`;
  // Nothing behind it can be reached: no focus, no click, no shortcut that would write the
  // in-memory Takes or Scripts back into the storage just cleared.
  for (const el of document.body.children) el.inert = true;
  document.activeElement?.blur();
  addEventListener('keydown', e => { e.stopImmediatePropagation(); e.preventDefault(); }, true);
  document.body.append(done);
}

document.addEventListener('keydown', e => {
  if ((e.metaKey || e.ctrlKey) && e.key === ',' && !document.body.classList.contains('first-running')) {
    e.preventDefault();
    if (sheet.hidden) openSettings(); else closeSettings();
  } else if (e.key === 'Escape' && !sheet.hidden && !alertBox.open) {   // an alert over the sheet takes Escape first
    e.preventDefault(); e.stopImmediatePropagation();
    if (subStack.length) { subStack.pop(); paintSettings(); } else closeSettings();
  }
}, true);

$('#view-opts').addEventListener('click', () => openSettings('Script timeline'));
applyScriptArea();
