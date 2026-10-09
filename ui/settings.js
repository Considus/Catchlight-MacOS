'use strict';
let shownPhrase = null;   // the phrase the Keychain gave for the page showing it, and no longer
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
  const loc = L10N.dateLocale([]);
  return t('Created on %1$@ at %2$@', d.toLocaleDateString(loc, { year: 'numeric', month: '2-digit', day: '2-digit' }), d.toLocaleTimeString(loc, { timeStyle: 'short' }));
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
  bellOff: '<path d="M6 16V11a6 6 0 0 1 9.5-4.9M18 11v5l1.5 2H8M10 20.5h4M4 4l16 16"/>',
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

const SPACING = [['compact', t('Compact')], ['standard', t('Standard')], ['comfort', t('Comfort')]];
const PREVIEW = [['single', t('Single')], ['some', t('Some')], ['all', t('All')]];
const ORDER = [['oldest', t('Oldest first')], ['newest', t('Newest first')]];

function settingsPage() {
  const folder = store.get('account', {})?.folder;
  const notif = settings.notifications === 'enabled' ? `<i class="sdot ok"></i>${t('Enabled')}` : t('Enable');
  return `<h2 class="page-heading">${t('Settings')}</h2>
  ${group(t('Appearance'), [
    pick('mode', 'mode', t('Mode'), [['auto', t('System')], ['daylight', t('Light')], ['night', t('Dark')]], () => scene),
    `<div class="srow off">${icon('palette')}<span class="srow-label">${t('Scenes')}</span><span class="srow-value">${t('Coming soon')}</span></div>`,
  ])}
  ${group(t('Dailies'), [
    pick('takeSpacing', 'spacing', t('View'), SPACING, () => settings.takeSpacing),
    pick('takePreview', 'preview', t('Preview'), PREVIEW, () => settings.takePreview),
    pick('takeSort', 'order', t('Order'), ORDER, () => settings.takeSort),
    pick('takeArrangement', 'hand', t('Arrangement'), [['date', t('Date')], ['manual', t('Manual')]], () => settings.takeArrangement),
    pick('creationStamp', 'calendar', t('Creation date'), [['off', t('Off')], ['editor', t('Editor only')], ['always', t('Always')]], () => settings.creationStamp),
  ])}
  ${group(t('Script timeline'), [
    pick('scriptSpacing', 'spacing', t('View'), SPACING, () => view.spacing),
    pick('scriptPreview', 'preview', t('Preview'), PREVIEW, () => view.preview),
    pick('scriptSort', 'order', t('Order'), ORDER, () => view.sort),
  ])}
  ${group(t('Script area'), [
    pick('scriptTextSize', 'textsize', t('Text size'), [['small', t('Small')], ['standard', t('Standard')], ['large', t('Large')]], () => settings.scriptTextSize),
    pick('newScriptPage', 'page', t('New Scripts'), [['region', regionPaper() === 'a4' ? t('Region (A4)') : t('Region (US Letter)')], ['continuous', t('Continuous')], ['a4', 'A4'], ['letter', t('US Letter')]], () => settings.newScriptPage),
    pick('spellcheck', 'spell', t('Spelling'), [['on', t('Check as I type')], ['off', t('Off')]], () => settings.spellcheck),
  ])}
  ${group(t('Reminders'), [
    pick('reminderHours', 'clock', t('Default timing'), [['1', t('1 hour')], ['6', t('6 hours')], ['12', t('12 hours')], ['24', t('1 day')], ['48', t('2 days')]], () => settings.reminderHours),
    pick('snooze', 'zzz', t('Snooze Duration'), [['5', t('5 mins')], ['15', t('15 mins')], ['30', t('30 mins')], ['60', t('1 hour')], ['360', t('6 hours')], ['720', t('12 hours')], ['1440', t('24 hours')]], () => settings.snooze),
    toggle('followUp', 'bell', t('Follow-up reminders'), t('Re-nudge until you mark it done'), settings.followUp),
  ])}
  ${group(t('Security'), [
    pick('lockAfter', 'lock', t('Lock after'), [['30', t('30 seconds')], ['60', t('1 minute')], ['300', t('5 minutes')], ['1800', t('30 minutes')], ['3600', t('1 hour')]], () => settings.lockAfter),
    pick('autoDelete', 'trash', t('Auto-Delete (exc. notes)'), [['never', t('Never')], ['daily', t('Daily')], ['weekly', t('Weekly')], ['monthly', t('Monthly')], ['annually', t('Annually')]], () => settings.autoDelete),
    toggle('confirmDelete', 'warn', t('Confirm before deleting'), t('A deleted Take cannot be recovered'), settings.confirmDelete),
    link('phrase', 'key', t('Privacy phrase')),
    link('second-device', 'device', t('Second device')),
    // How much of each Take the OS search may index (SpotlightExposure, D-110). Past the type
    // label it puts decrypted text in the OS index; the two text levels stay locked, as on
    // iOS, until the platform's search can find them.
    pick('spotlight', 'search', PLATFORM.text.search(), [['none', t('None')], ['type', t('Type only')], ['firstLine', t('Type + first line'), true], ['all', t('Type + full text'), true]],
      () => settings.spotlight, t('On-device search only. Considus can never read your Takes. Text levels are greyed out until search can find them.')),
    // Writing Tools (D-246) is Apple's, so only the Mac has the row. Off by default: the
    // editor would otherwise inherit it, and either mode sends that Take to Apple.
    PLATFORM.writingTools ? pick('writingTools', 'wand', t('Writing Tools'), [['off', t('Off')], ['panel', t('Panel')], ['inline', t('Inline')]],
      () => settings.writingTools, t('Panel suggests, you accept. Inline rewrites in place. Both send that Take to Apple. Your Privacy phrase never goes.')) : '',
  ])}
  ${group(t('System'), [
    link('notifications', 'bell', t('Notifications'), notif, settings.notifications !== 'enabled'),
    link('cloud', 'cloud', t('Cloud Storage'), folder ? esc(folder.split('/').pop()) : t('Not configured')),
    link('export', 'export', t('Export Takes'), '', false),
    folder ? link('import-notes', 'import', t('Import notes'), '', false) : '',
    link('import-file', 'file', t('Import from a file'), '', false),
    link('about', 'info', t('About'), t('Catchlight 0.1 (prototype)')),
    link('start-over', 'restart', t('Start over'), '', false, ' danger'),
  ], t('Erases every Take here and creates a new Privacy phrase. Cloud copies become unreadable too. Export first, it is the only way back.'))}
  ${group(t('Support'), [
    link('report', 'bug', t('Report an issue'), '', false),
    link('notices', 'list', t('Notice History')),
    link('diagnostics', 'export', t('Export diagnostics'), '', false),
  ])}`;
}

// ---------- sub-screens ----------
const SUB = {
  cloud: () => {
    const folder = store.get('account', {})?.folder;
    const modes = { automatic: t('Syncs automatically in the background and when you open the app.'), manual: t('Only syncs when you click Sync Now.'), disabled: PLATFORM.text.neverSyncs() };
    return [t('Cloud Storage'), `<div class="ssub-col">
      <h2 class="ssub-heading">${t('Choose a cloud folder you own')}</h2>
      <p>${t("Select an empty folder, or create a new one, and we'll take care of the rest.")}</p>
      <p class="quiet">${t('Catchlight never sees your files. Only you can read them.')}</p>
      ${folder ? `<p class="sfolder">✓ ${esc(folder)}</p>` : ''}
      <button class="fr-pill primary" type="button" data-act="pick-folder">${t('Choose folder')}</button>
      ${folder ? `<button class="slink danger" type="button" data-act="remove-folder">${t('Remove')}</button>` : ''}
      <p class="sfine">${t("Tested with iCloud Drive, Dropbox, Internxt, Koofr and Filen. Others may work. You'll need the provider's app installed and signed in.")}</p>
      <hr>
      <div class="sgroup">${pick('syncMode', 'cloud', t('Sync'), [['automatic', t('Automatic')], ['manual', t('Manual')], ['disabled', t('Disabled')]], () => settings.syncMode)}</div>
      <p class="quiet">${modes[settings.syncMode]}</p>
      ${settings.syncMode === 'manual' ? `<button class="slink" type="button" data-act="sync-now"${folder ? '' : ' disabled'}>${t('Sync Now')}</button>` : ''}
    </div>`];
  },
  about: () => [t('About'), `<div class="ssub-col">
      ${brandMark()}
      <h2 class="ssub-heading">${t('Privacy-first notes and reminders')}</h2>
      <p class="quiet sversion" tabindex="0" data-copy-info title="${esc(t('Right-click to copy version and device info'))}">${t('Version 0.1 (prototype)')}</p>
      <div class="scard"><h4>${t('Open Source Licences')}</h4>
        <p>${t('Cormorant Garamond and DM Sans, under the SIL Open Font License 1.1. The licence text for each is beside the fonts and listed in NOTICE.')}</p>
        <p class="quiet">${t('The BIP-39 English wordlist is sourced from the Trezor project and bundled under the MIT licence.')}</p></div>
      <div class="scard links">${[[t('Privacy Policy'), 'https://catchlight.app/privacy/'], [t('Terms of Service'), 'https://catchlight.app/terms/'], [t('Support'), 'https://catchlight.app/support/?platform=' + PLATFORM.osName], [t('Website'), 'https://catchlight.app']]
        .map(([l, u]) => `<a href="${u}" target="_blank" rel="noopener">${l}<span aria-hidden="true">↗</span></a>`).join('')}</div>
      <p class="quiet small">${t('Made by Considus')}</p></div>`],
  phrase: () => [t('Privacy phrase'), `<div class="ssub-col">
      <h2 class="ssub-heading">${t('Reveal your Privacy phrase')}</h2>
      <p>${t("Authenticate with Touch ID or your password to view the 12 words. They're the only way to recover your account, so reveal them somewhere private.")}</p>
      <button class="fr-pill primary" type="button" data-act="reveal-phrase">${t('Reveal phrase')}</button></div>`],
  'phrase-shown': () => {
    const words = shownPhrase ?? store.get('account', {})?.phrase;
    if (!words) return [t('Privacy phrase'), `<div class="ssub-col"><h2 class="ssub-heading">${t("Phrase isn't on this device")}</h2>
      <p>${t('Catchlight stores the Privacy phrase only on the device where you set it up. If you onboarded on a different device, use that one to view it.')}</p></div>`];
    // The 12 words are BIP-39 English and part of the key: never translated.
    return [t('Privacy phrase'), `<div class="ssub-col">
      <ol class="fr-words" data-phrase aria-label="${esc(t('Privacy phrase'))}" aria-hidden="true">${words.map((w, i) => `<li><span>${i + 1}</span><b class="held">${esc(w)}</b></li>`).join('')}</ol>
      <p>${t("Write these 12 words down somewhere safe, on paper. They're the only way back into your Takes on a new device.")}</p>
      <button class="fr-pill primary hold" type="button" data-hold>${t('Hold to reveal')}</button></div>`];
  },
  'second-device': () => [t('Second device'), `<div class="ssub-col">
      <div class="swarn">${PLATFORM.text.secondDevice()}</div>
      <h2 class="ssub-heading">${t('Enter your Privacy phrase')}</h2>
      <p>${t('The 12 words from your other device, in order.')}</p>
      ${phraseGrid()}
      <p class="fr-status" id="sd-status" aria-live="polite">${t('%lld of 12 words', 0)}</p>
      <button class="fr-pill primary" type="button" data-act="sd-restore" disabled>${t('Restore on this device')}</button></div>`],
  // NoticeHistoryView: the user-facing notices, newest first, each with its category's icon and
  // a relative time; Clear empties them. Lifecycle entries stay in diagnostics, as on iOS.
  notices: () => {
    const shown = noticesShown();
    return [t('Notice History'), shown.length ? `<div class="snotice-bar"><button class="slink" type="button" data-act="clear-notices">${t('Clear')}</button></div>
      <div class="sgroup">${shown.map(n => `<div class="srow tall snotice" role="group" aria-label="${esc(t('%1$@. %2$@', kindOf(n).name, n.message))}" aria-description="${ago(n.at)}">
        <svg class="srow-icon ${kindOf(n).tint}" viewBox="0 0 24 24" aria-hidden="true">${kindOf(n).icon}</svg><span class="srow-label">${esc(n.message)}<small>${ago(n.at)}</small></span></div>`).join('')}</div>`
      : `<div class="ssub-col empty-col">${icon('bellOff')}<h2 class="ssub-heading">${t('No notices yet')}</h2><p class="quiet">${t('Sync, storage and conflict notices will appear here.')}</p></div>`];
  },
};

// ---------- the sheets ----------
const sheet = $('#settings');
let subStack = [];
function paintSettings(keepScroll = true) {
  sheet.classList.remove('revealing');   // the phrase never stays revealed past its own page
  if (subStack.at(-1) !== 'phrase-shown') shownPhrase = null;   // nor kept once its page has gone
  const scroll = sheet.querySelector('.sheet-scroll')?.scrollTop || 0;
  const top = subStack.at(-1);
  const [title, body] = top ? SUB[top]() : [null, settingsPage()];
  sheet.innerHTML = `<div class="sheet-panel${top ? ' sub' : ''}" role="dialog" aria-modal="true" aria-label="${esc(title || t('Settings'))}">
    <div class="sheet-bar">${top ? `<button class="sheet-back" type="button" data-act="back" aria-label="${esc(t('Back'))}">${CHEV}</button><span class="sheet-title">${title}</span>` : '<span></span>'}
      <button class="sheet-x" type="button" data-act="close" aria-label="${esc(t('Close %@', title || t('Settings')))}"><svg viewBox="0 0 24 24"><path d="M6.5 6.5l11 11M17.5 6.5l-11 11"/></svg></button></div>
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
  sheet.classList.remove('revealing');
  shownPhrase = null;
  sheet.classList.remove('open');
  ctx.hidden = true;   // About's menu sits over the sheet
  setTimeout(() => { if (!sheet.classList.contains('open')) { sheet.hidden = true; sheet.innerHTML = ''; } }, still.matches ? 0 : 300);
}
// A notice is { category, message, at }, as DiagnosticsLog keeps it; `category` is one of
// NOTICE_KIND. Sync, storage, conflict and quarantine are shown; lifecycle is not (iOS keeps it
// for Export diagnostics). Older prototype entries were plain strings, read as sync notices.
const NOTICE_KIND = {
  sync: { name: t('Sync'), tint: 'accent', icon: '<path d="M5 12a7 7 0 0 1 12-5l2 2M19 12a7 7 0 0 1-12 5l-2-2M19 4v5h-5M5 20v-5h5"/>' },
  storage: { name: t('Storage'), tint: 'ruby', icon: '<rect x="4" y="12" width="16" height="7" rx="2"/><path d="M7 15.5h.5M12 4v5M12 10.5v.5"/>' },
  conflict: { name: t('Conflict'), tint: 'accent', icon: '<path d="M7 4v6a4 4 0 0 0 4 4h6M17 14l-3-3M17 14l-3 3M7 20v-6"/>' },
  quarantine: { name: t('Quarantine'), tint: 'ruby', icon: '<rect x="5.5" y="10.5" width="13" height="10" rx="2"/><path d="M8.5 10.5V8a3.5 3.5 0 0 1 6.6-1.6M4 4l16 16"/>' },
  lifecycle: { name: t('App'), tint: 'accent', icon: SI.info },
};
const noticeList = () => (settings.notices.length || !SAMPLE_NOTICES ? settings.notices : SAMPLE_NOTICES).map(n => typeof n === 'string' ? { category: 'sync', message: n, at: 0 } : n);
const kindOf = n => NOTICE_KIND[n.category] || NOTICE_KIND.sync;   // an unknown category still draws
const noticesShown = () => noticeList().filter(n => n.category !== 'lifecycle');
// Built from the saved list only, so ?notices samples are never written into it.
const notice = (message, category = 'sync') => { settings.notices = [{ category, message, at: Date.now() }, ...settings.notices]; saveSettings(); };
// "2 minutes ago", "yesterday": the relative, named style iOS uses.
function ago(at) {
  if (!at) return '';
  const s = (at - Date.now()) / 1000, rtf = new Intl.RelativeTimeFormat(L10N.dateLocale([]), { numeric: 'auto' });
  // The largest unit it is at least 95% of, so 59.6 minutes reads "1 hour ago", not "60 minutes ago".
  for (const [unit, n] of [['year', 31536000], ['month', 2592000], ['week', 604800], ['day', 86400], ['hour', 3600], ['minute', 60]]) if (Math.abs(s) >= n * 0.95) return rtf.format(Math.round(s / n) || Math.sign(s), unit);
  return rtf.format(0, 'second');
}
// ?notices: sample entries, to look at the list before a shell produces real ones.
// Read in place of the saved list, never written into it, so a setting changed while looking
// doesn't keep them.
let SAMPLE_NOTICES = new URLSearchParams(location.search).has('notices') && [
  { category: 'sync', message: 'Synced 3 Takes from your cloud folder.', at: Date.now() - 2 * 60e3 },
  { category: 'conflict', message: 'Two versions of a Take were edited. Both are kept.', at: Date.now() - 26 * 36e5 },
  { category: 'storage', message: "The cloud folder couldn't be reached. Your Takes are safe on this Mac.", at: Date.now() - 4 * 864e5 },
];

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
  else if (act === 'pick-folder') Promise.resolve(shell.chooseFolder()).then(f => { if (f) { store.set('account', { ...store.get('account', {}), folder: f }); paintSettings(); } }).catch(folderRefused);
  else if (act === 'remove-folder') { shell.forgetFolder?.(); store.set('account', { ...store.get('account', {}), folder: null }); paintSettings(); }
  else if (act === 'sync-now') {
    e.target.textContent = t('Syncing…'); e.target.disabled = true;
    // In the Mac app a real pass, through the shell; in a browser the prototype's pause.
    const pass = window.catchlightBridge ? catchlightBridge.sync('manual') : new Promise(r => setTimeout(r, 2000));
    pass.finally(() => paintSettings());
  }
  else if (act === 'sd-restore') secondDeviceRestore();
  else if (act === 'reveal-phrase') {
    // In the Mac app the words come from the Keychain, which asks for Touch ID or the password.
    if (window.catchlightBridge?.library) shell.revealPhrase().then(w => { if (!w) return; shownPhrase = w; subStack.push('phrase-shown'); paintSettings(); }).catch(() => {});   // no words: the prompt was cancelled
    else { subStack.push('phrase-shown'); paintSettings(); }
  }
  else if (act === 'clear-notices') { settings.notices = noticeList().filter(n => n.category === 'lifecycle'); SAMPLE_NOTICES = null; saveSettings(); paintSettings(); }   // clearUserFacing: the lifecycle breadcrumbs stay
  else if (open && SUB[open]) {
    const go = () => { subStack.push(open); paintSettings(); if (open === 'second-device') sheet.querySelector('[data-word="0"]').focus(); };
    if (open !== 'second-device') go();
    else ask(t('Add this device to your account?'), t("Enter your Privacy phrase to bring your Takes onto this device. Any Takes stored only on this device will be removed. To keep a copy first, cancel and use Export Takes (Markdown), or make sure they're already in your cloud folder."),
      [[t('Cancel'), null, 'cancel'], [t('Continue'), go, 'danger']]);
  }
  else if (open === 'notifications' && settings.notifications !== 'enabled') { settings.notifications = 'enabled'; saveSettings(); paintSettings(); }
  else if (open === 'export') exportTakes(takes);
  else if (open === 'import-notes') importNotes();
  else if (open === 'import-file') importFromFile();
  else if (open === 'report') window.open(reportUrl(), '_blank', 'noopener');
  else if (open === 'diagnostics') ask(t('Export diagnostics'), t("The log is written by the shell, which doesn't exist yet."), [[t('OK'), null, 'cancel']]);
  else if (open === 'start-over') startOver();
  if (open === 'notices') paintSettings();
});

// Second device: the same entry grid as first run. Core checks the words; here, their shape.
function paintSecondDevice(error) {
  const n = phraseWords(sheet).filter(Boolean).length, status = $('#sd-status');
  status.classList.toggle('error', !!error);
  status.textContent = error || (n === 12 ? t('Ready to restore.') : t('%lld of 12 words', n));
  sheet.querySelector('[data-act="sd-restore"]').disabled = n < 12;
}
async function secondDeviceRestore() {
  if (sheet.querySelector('[data-act="sd-restore"]').disabled) return;
  const words = phraseWords(sheet).map(w => w.toLowerCase());
  if (!await shell.phraseLooksValid(words)) { paintSecondDevice(t("That doesn't look right. Check the words and try again.")); return; }
  // In the Mac app the shell swaps the account first (Vault.replaceAccount): nothing is erased,
  // the library stays if the phrase opens it and is moved aside if not, and the phrase becomes
  // the account here. Nothing on the page changes unless that worked.
  // It answers with the library now open, which welcomeBack's finish() shows without saving.
  if (window.catchlightBridge?.library) {
    try { fr.opened = await shell.replaceAccount(words); } catch (e) { paintSecondDevice(t("Couldn't add this Mac: %@", String(e))); return; }
  }
  if (draft) discardEdit();   // a Take being written belongs to the account being replaced
  // As on iOS, this replaces the account here: Takes stored only on this device go, and so
  // does the phrase kept from first run, which is no longer this account's.
  // The old cloud folder belongs to the account being replaced, so it goes too (AppModel).
  store.set('account', { ...store.get('account', {}), restored: true, phrase: undefined, folder: null });
  if (window.catchlightBridge?.library) adoptLibrary(fr.opened);
  else {
    takes = []; saveTakes(); renderTakes();
    scripts = []; current = null; save(); renderScripts(); renderDoc(); $('#script-heading').textContent = '';
  }
  closeSettings();
  welcomeBack();   // first-run.js: Welcome back, Not now or Connect cloud folder
}
// Wired once first-run.js, which owns the grid, has loaded.
addEventListener('DOMContentLoaded', () => wirePhraseEntry(sheet, () => paintSecondDevice(), secondDeviceRestore));

// Hold to reveal: the words show only while the button is held. From the keyboard, Space or
// Return shows them and a second press hides them, as iOS offers Reveal and Hide as actions.
sheet.addEventListener('keydown', e => {
  const b = e.target.closest('[data-hold]');
  if (!b || (e.key !== ' ' && e.key !== 'Enter')) return;
  e.preventDefault();
  if (e.repeat) return;   // a held key is one press
  const on = !sheet.classList.contains('revealing');
  sheet.classList.toggle('revealing', on);
  b.textContent = on ? t('Hide phrase') : t('Hold to reveal');
  b.setAttribute('aria-pressed', String(on));
  sheet.querySelector('[data-phrase]')?.setAttribute('aria-hidden', String(!on));   // the words are read only while shown
});
sheet.addEventListener('pointerdown', e => {
  const b = e.target.closest('[data-hold]');
  if (!b) return;
  const words = sheet.querySelector('[data-phrase]');
  sheet.classList.add('revealing'); b.textContent = t('Release to hide'); words?.setAttribute('aria-hidden', 'false');
  const end = () => { sheet.classList.remove('revealing'); b.textContent = t('Hold to reveal'); b.setAttribute('aria-pressed', 'false'); words?.setAttribute('aria-hidden', 'true'); removeEventListener('pointerup', end); removeEventListener('pointercancel', end); };
  addEventListener('pointerup', end); addEventListener('pointercancel', end);
});

// About's version line copies a short, paste-ready support block (AboutView.supportInfoString):
// version, OS and model, and nothing from the user's Takes. Right-click it, or ⇧F10 from the
// keyboard, as VoiceOver's named action on iOS.
// The support page, told the platform, the app version and the OS version, and nothing else
// (SettingsView.reportAnIssue).
const reportUrl = () => 'https://catchlight.app/support/?' + new URLSearchParams({ platform: PLATFORM.osName, app: '0.1', os: shell.osVersion() });
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
  ask(t('Export your Takes?'), t('Export Takes now. This is the only way to preserve them. This will make cloud copies unreadable.'), [
    [t('Export Takes'), () => exportTakes(takes)],
    [t('Erase. Takes exported'), () => ask(t('Erase everything on this device?'), t('This deletes every Take on this device and the Privacy phrase that unlocks them. Takes in your cloud folder will be unreadable. This cannot be undone.'),
      [[t('Cancel'), null, 'cancel'], [t('Erase everything'), eraseEverything, 'danger']]), 'danger'],
    [t('Cancel'), null, 'cancel'],
  ]);
}
// The shell couldn't keep access to the folder picked (it couldn't make a bookmark to it): say so,
// rather than let the panel close as if nothing had been chosen.
const folderRefused = e => ask(t("Catchlight can't use that folder"), t('Choose another folder, or the same one again. If this keeps happening, report it with this detail: %@', String(e?.message ?? e)), [[t('OK'), null, 'cancel']]);

async function eraseEverything() {
  // In the Mac app the Keychain items and the encrypted library go first; if that fails, the
  // page says so and keeps everything as it was.
  if (window.catchlightBridge?.library) {
    try { await shell.eraseEverything(); window.catchlightBridge.library.account = false; }
    catch (e) { ask(t("Couldn't erase everything"), String(e), [[t('OK'), null, 'cancel']]); return; }
  }
  Object.keys(localStorage).filter(k => k.startsWith('cl.')).forEach(k => { try { localStorage.removeItem(k); } catch {} });
  closeSettings();
  const done = document.createElement('section');
  done.className = 'reset-done'; done.setAttribute('role', 'alert');
  done.innerHTML = `<h1>${t('Catchlight has been reset')}</h1><p>${t('Quit Catchlight and open it again to set up a new Privacy phrase. If you exported your Takes, you can bring them back with Import from a file.')}</p>`;
  // Nothing behind it can be reached: no focus, no click, no shortcut that would write the
  // in-memory Takes or Scripts back into the storage just cleared.
  for (const el of document.body.children) el.inert = true;
  document.activeElement?.blur();
  addEventListener('keydown', e => { e.stopImmediatePropagation(); e.preventDefault(); }, true);
  document.body.append(done);
}

// ⌘, (Ctrl+, elsewhere) is the menu's Settings item, menu.js.
document.addEventListener('keydown', e => {
  if (e.key === 'Escape' && !sheet.hidden && !alertBox.open) {   // an alert over the sheet takes Escape first
    e.preventDefault(); e.stopImmediatePropagation();
    if (subStack.length) { subStack.pop(); paintSettings(); } else closeSettings();
  }
}, true);

$('#view-opts').addEventListener('click', () => openSettings(t('Script timeline')));
applyScriptArea();

// ---------- Import (SettingsView.importNotes / importFromFile on iOS) ----------
// The shell reads the files and writes the Takes (NoteImport.swift); the page asks, then shows
// what happened in the iPhone's words. A Catchlight export splits back into its Takes, and a
// Script exported as one comes back as a Script.
function importNotes() {
  ask(t('Import notes'), t('Any items in the folder, that have previously been imported, will be imported again.'), [
    [t('Proceed'), () => runImport('importNotes')], [t('Cancel'), null, 'cancel']]);
}
function importFromFile() { runImport('importFile'); }
async function runImport(cmd) {
  if (!window.catchlightBridge?.importNotes) {
    return ask(cmd === 'importNotes' ? t('Import notes') : t('Import from a file'), t("Importing needs the app: the page alone can't read your files."), [[t('OK'), null, 'cancel']]);
  }
  let r;
  try { r = await catchlightBridge[cmd](); }
  catch (e) { console.error('Import failed', e); return ask(t('Import'), t("Couldn't open those files. Please try again."), [[t('OK'), null, 'cancel']]); }
  if (r?.cancelled) return;
  const say = (...sentences) => ask(cmd === 'importNotes' ? t('Import notes') : t('Import from a file'), L10N.sentences(...sentences), [[t('OK'), null, 'cancel']]);
  if (r?.noFolder) return say(t('Set up Cloud Storage first. The Import folder lives inside your sync folder.'));
  if (r?.unreadable) return say(t("The Import folder couldn't be read. Check your cloud folder in Settings → Cloud Storage and try again."));
  const n = (r?.takes || 0) + (r?.scripts || 0);
  // Notes read but not written (the library refused them) are never reported as missing files
  // or hidden behind a success: re-importing brings everything in again, so say what didn't land.
  const failed = !r?.failed ? '' : r.failed === 1
    ? t("One note couldn't be saved. Import again to try them, and if it keeps happening, report it.")
    : t("%lld notes couldn't be saved. Import again to try them, and if it keeps happening, report it.", r.failed);
  if (!n && r?.failed) return say(t('Nothing was imported.'), failed);
  if (!n) return say(cmd === 'importNotes' ? t('No recognised markdown or text files found in the Import folder.') : t('No notes to import from your selection.'));
  await catchlightBridge.refresh().catch(e => console.error('Refreshing after an import failed', e));
  say(!r.scripts ? t('Import successful. %lld Takes added to your timeline.', r.takes)
    : !r.takes ? t('Import successful. %lld Scripts added to your timeline.', r.scripts)
    : t('Import successful. %1$lld Takes and %2$lld Scripts added to your timeline.', r.takes, r.scripts), failed);
  catchlightBridge.sync?.('save').catch?.(e => console.error('Sync after an import failed', e));
}
