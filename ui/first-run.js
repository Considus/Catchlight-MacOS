'use strict';
// First run (D-327): the desktop needs no phone. It creates a Privacy phrase itself, as the
// iPhone's OnboardingView does, or takes an existing one typed in. Screens, order and copy
// follow iOS (As-Built, D-274); where the desktop differs it says so. Loaded after app.js and
// takes.js. Placeholder only: generating and checking a phrase, the Keychain and the folder
// picker are Core's and the shell's, reached through `shell` below.

// What the copy names, per desktop (D-318). The shell says which it is; ?platform=windows or
// ?platform=linux previews the others. The backup lines are only true because each shell keeps
// the Takes out of that platform's backup (ui/README.md, "What each shell must do").
const PLATFORMS = {
  mac: { osName: 'macOS', sampleOs: '26.0', sampleModel: 'Mac16,1', device: 'Mac', settingsKey: '⌘,', settingsWhere: 'Settings from the Catchlight menu', search: 'Spotlight & Siri', writingTools: true, noBackup: "Time Machine won't contain them", keptOut: 'because we deliberately keep them out of it' },
  windows: { osName: 'Windows', sampleOs: '11 24H2', sampleModel: 'Surface Laptop 7', device: 'PC', settingsKey: 'Ctrl+,', settingsWhere: 'Settings from the File menu', search: 'Windows Search', noBackup: "Windows Backup and File History won't contain them", keptOut: 'because we deliberately keep them out of both' },
  // Named, as Time Machine is: only Déjà Dup honours the marker the shell writes, and a general
  // "your backups" would be untrue for rsync or Borg.
  linux: { osName: 'Linux', sampleOs: 'Ubuntu 24.04', sampleModel: 'ThinkPad X1 Carbon', device: 'computer', settingsKey: 'Ctrl+,', settingsWhere: 'Preferences from the File menu', search: 'Desktop search', noBackup: "Déjà Dup won't contain them", keptOut: 'because we deliberately keep them out of it' },
};
const PLATFORM = PLATFORMS[new URLSearchParams(location.search).get('platform')] || PLATFORMS.mac;

// Stand-ins for the shell bridge. The real phrase is BIP-39 from Core (128 bits, 12 words,
// checksum, all different); these words are a sample of that list and carry no checksum.
const SAMPLE_WORDS = ('anchor badge canvas dawn ember fabric glimpse harbor island jacket kettle lantern meadow '
  + 'noble orbit pencil quarter ribbon saddle timber umbrella velvet wagon yellow zebra amber bridge cactus '
  + 'denim engine falcon garden hollow inner jungle kingdom ladder marble nephew olive planet rescue silver '
  + 'tunnel unique violin window').split(' ');
const shell = {
  newPhrase() {
    const pool = [...SAMPLE_WORDS];
    return Array.from({ length: 12 }, () => pool.splice(crypto.getRandomValues(new Uint32Array(1))[0] % pool.length, 1)[0]);
  },
  // Core checks the words are on the list and the checksum holds. Here, only the shape:
  // twelve words of 3 to 8 letters, which every BIP-39 English word is.
  phraseLooksValid: words => words.length === 12 && words.every(w => /^[a-z]{3,8}$/.test(w)),
  chooseFolder: () => '~/Dropbox/Catchlight',   // the native folder picker, via the shell
  // The OS version and hardware model for About's copy line. A browser can't read either
  // truthfully, so the prototype stands in a sample of what the shell returns.
  // The OS version and model, for About and Report an issue; a sample of what each shell reports.
  systemInfo: () => `${PLATFORM.osName} ${shell.osVersion()} · ${PLATFORM.sampleModel}`,
  osVersion: () => PLATFORM.sampleOs,
  copyText: text => navigator.clipboard?.writeText(text),
};
// In a shell, the real thing (bridge.js).
if (window.catchlightBridge) Object.assign(shell, window.catchlightBridge.shell);

const fr = { step: null, storage: null, words: [], positions: [], picked: [], bank: [], basics: 0, folder: null, restore: false };
const layer = $('#first-run');

const BRAND = brandMark;
const pill = (act, label, cls = '') => `<button class="fr-pill${cls}" type="button" data-fr="${act}">${label}</button>`;

const SCREENS = {
  splash: () => `<p class="fr-tagline">Every thought deserves a moment of clarity.</p>
    <p class="fr-foot">© 2026 Considus</p>`,

  welcome: () => `<h2>You don't need to choose privacy, it's yours and you never have to ask for it.</h2>
    <p>First, we'll create your Privacy phrase: 12 words that are the <b>ONLY</b> key to your data.</p>
    <p>We never see them, store them, or ask for them. So don't lose them.</p>
    <div class="fr-actions">${pill('restore', 'I already use Catchlight', ' link')}${pill('create', 'Create my Privacy phrase', ' primary')}</div>`,

  storage: () => `<h2>Now, where should your Takes live?</h2>
    <button class="fr-card" type="button" data-fr="local"><b>Local: on this ${PLATFORM.device} only</b>
      <span>Your Takes stay on this ${PLATFORM.device} and nowhere else. ${PLATFORM.noBackup}, so if the ${PLATFORM.device} goes, they go with it.</span></button>
    <button class="fr-card" type="button" data-fr="cloud"><b>Cloud: backed up and restorable</b>
      <span>Connect a cloud folder you control. Your Takes stay encrypted, we never see them, and your 12 words are what open them again on any other device.</span></button>`,

  localWarning: () => `<h2>One thing before we continue.</h2>
    <p>Your Takes will live on this ${PLATFORM.device} and nowhere else. ${PLATFORM.noBackup}, ${PLATFORM.keptOut}. Lose this ${PLATFORM.device} or wipe it, and there's nothing to restore from.</p>
    <div class="fr-actions">${pill('back-storage', 'Go back')}${pill('risk', 'I know the risk', ' primary')}</div>`,

  // The desktop picks the folder here (D-327); the phone leaves it to Settings.
  folder: () => `<h2>Choose a cloud folder you own</h2>
    <p>Select an empty folder, or create a new one, and we'll take care of the rest.</p>
    <p>Catchlight never sees your files. Only you can read them.</p>
    ${fr.folder ? `<p class="fr-folder">${esc(fr.folder)}</p>` : ''}
    <div class="fr-actions">${fr.folder
      ? pill('pick-folder', 'Choose another') + pill('folder-done', 'Continue', ' primary')
      : pill('back-storage', 'Go back') + pill('pick-folder', 'Choose folder', ' primary')}</div>`,

  reveal: () => `<h2>Your Privacy phrase</h2>
    <ol class="fr-words">${fr.words.map((w, i) => `<li><span>${i + 1}</span>${w}</li>`).join('')}</ol>
    <p>${fr.storage === 'local'
      ? 'Write these 12 words down and keep them somewhere safe. They encrypt your Takes and enable a second device.'
      : "Write these 12 words down and keep them somewhere safe. You'll need them to open your Takes on any other device, so the copy you write down is the copy that counts."}</p>
    <div class="fr-actions">${pill('written', "I've written them down", ' primary')}</div>`,

  confirm: () => {
    const [a, b, c] = fr.positions.map(p => p + 1);
    return `<div class="fr-error" id="fr-error" role="alert" tabindex="-1" hidden>Those aren't quite right. Try again.</div>
    <h2>Confirm three words</h2>
    <p>Click words ${a}, ${b} and ${c} from your phrase, in order.</p>
    <div class="fr-slots">${fr.positions.map((p, i) => `<button class="fr-slot" type="button" data-slot="${i}"><span>${p + 1}</span>${fr.picked[i] != null ? fr.bank[fr.picked[i]] : '—'}</button>`).join('')}</div>
    <div class="fr-bank">${fr.bank.map((w, i) => `<button class="fr-tile" type="button" data-tile="${i}"${fr.picked.includes(i) ? ' disabled' : ''}>${w}</button>`).join('')}</div>
    <div class="fr-actions">${pill('show-again', 'Show my words once more')}</div>`;
  },

  basics: () => {
    const page = fr.basics === 0
      ? [['Add a Take', "Click the + button. Click anywhere outside the Take to save. That's the whole capture flow."],
         ['Shape your Take with the Iris', 'Click the circle beside any Take to make it a task, set a reminder, or make it important.']]
      : [['Your Obie', "Press and hold an Iris to pin one above the rest. Only one is ever your Obie, because there can only be one that's most important."],
         ['Scripts', 'Longer writing lives in Scripts, on the right. They never reach your phone.']];
    return `<h2>A few things worth knowing</h2>
      ${page.map(([h, p]) => `<div class="fr-basic"><b>${h}</b><p>${p}</p></div>`).join('')}
      <div class="fr-actions">${pill('basics-next', fr.basics === 0 ? 'Next' : 'Got it', ' primary')}</div>`;
  },

  complete: () => `<h2>You're ready.</h2>
    <p class="fr-strong">Your thoughts, in your order, telling your story. Nobody else's.</p>
    <p>${fr.storage === 'local'
      ? `Encrypted on this ${PLATFORM.device}, readable only by you.`
      : `Encrypted on this ${PLATFORM.device}, readable only by you, and kept in the folder you chose.`}</p>
    <div class="fr-actions">${pill('finish', 'Start using Catchlight', ' primary')}</div>`,

  restore: () => `<h2>Enter your Privacy phrase</h2>
    ${phraseGrid()}
    <p>The 12 words from your other device, in order.</p>
    <p class="fr-status" id="fr-status" aria-live="polite">0 of 12 words</p>
    <div class="fr-actions">${pill('back-welcome', 'Back')}${pill('do-restore', 'Restore', ' primary')}</div>`,

  restored: () => `<h2>Welcome back</h2>
    <p>Your account is restored on this ${PLATFORM.device}. Connect the cloud folder where your Takes are saved and they'll appear here.</p>
    <div class="fr-actions">${pill('finish', 'Not now', ' link')}${pill('connect-folder', 'Connect cloud folder', ' primary')}</div>`,
};

function show(step) {
  fr.step = step;
  layer.dataset.step = step;
  layer.innerHTML = `<div class="fr-column">${BRAND()}<div class="fr-body">${SCREENS[step]()}</div></div>`;
  if (step === 'restore') { paintRestoreStatus(); layer.querySelector('[data-word="0"]').focus(); }
  else layer.querySelector('.fr-pill.primary, .fr-card')?.focus();
}

function newConfirm() {
  const pos = new Set();
  while (pos.size < 3) pos.add(crypto.getRandomValues(new Uint32Array(1))[0] % 12);
  fr.positions = [...pos].sort((a, b) => a - b);
  fr.bank = [...fr.words].sort(() => Math.random() - 0.5);
  fr.picked = [];
}

function checkConfirm() {
  if (fr.picked.length < 3) return;
  const right = fr.positions.every((p, i) => fr.bank[fr.picked[i]] === fr.words[p]);
  if (right) { fr.basics = 0; show('basics'); return; }
  $('#fr-error').hidden = false;
  layer.querySelectorAll('.fr-slot').forEach(s => s.classList.add('wrong'));
  setTimeout(() => { if (fr.step === 'confirm') { fr.picked = []; show('confirm'); $('#fr-error').hidden = false; $('#fr-error').focus(); } }, 600);
}

const restoreWords = () => phraseWords(layer);
function paintRestoreStatus(error) {
  const n = restoreWords().filter(Boolean).length, status = $('#fr-status');
  status.classList.toggle('error', !!error);
  status.textContent = error || (n === 12 ? 'Ready to restore.' : `${n} of 12 words`);
  layer.querySelector('[data-fr="do-restore"]').disabled = n < 12;
}
// The shell's check is a promise; the prototype's stand-in answers at once.
async function doRestore() {
  const words = restoreWords().map(w => w.toLowerCase());
  if (await shell.phraseLooksValid(words)) { fr.restore = true; fr.restoreWords = words; show('restored'); }
  else paintRestoreStatus("That doesn't look right. Check the words and try again.");
}

// iOS's Take.init leaves isNote on, so every seed lights the Note blade too.
// The five starter Takes a new account opens with, in lesson order, oldest first (SeedTakes in
// Catchlight-Core, the owner's words). Three phrases are the desktop's: clicking the Iris rather
// than touching it, right-click beside swiping, and the Settings shortcut in place of a swipe
// up. A restored account gets none: its Takes come from the cloud folder.
function seedTakes() {
  const now = Date.now(), at = s => new Date(now + s * 1000).toISOString();
  return [
    { id: newId(), at: at(-50), isNote: true, blocks: [{ k: 'text', text: "A Take is like memory, the place to keep your ideas and it's simply easy. Try clicking the Iris on a Take, you'll see how effortless shaping a Take really is. Make it an Obie, task or add a reminder - do all of them or none of them, you're in control." }] },
    { id: newId(), at: at(-40), isNote: true, blocks: [{ k: 'text', text: 'Sometimes you need more structure, so when you need a list or plan to work from, add a task to your Take, yes, any Take, and give yourself time.' }, { k: 'check', text: 'Give yourself time to act', done: false }] },
    { id: newId(), at: at(-30), isNote: true, reminder: { when: at(86400), done: false }, blocks: [{ k: 'text', text: "When timing is everything, use a reminder. These can be added to any Take; doesn't matter if it's a note, a task or both. When you need to be nudged, poked or pushed, reminders are invaluable." }] },
    { id: newId(), at: at(-20), isNote: true, obie: true, isImportant: true, blocks: [{ k: 'text', text: "Only one Take is ever an Obie, that special memory or activity that's above all others. That's because you can only ever have one thought that's your most important and this is where it lives, always." }] },
    { id: newId(), at: at(-10), isNote: true, blocks: [{ k: 'text', text: `Delete these introductory Takes whenever you're ready, easy as swiping left on a Take, or right-clicking it. This is your Catchlight, use it in the way that fits you perfectly. Oh and, if you need to check out customisation and settings, press ${PLATFORM.settingsKey} or choose ${PLATFORM.settingsWhere}.` }] },
  ];
}

// The library the shell has just opened, shown as it is: nothing is saved back.
function adoptLibrary({ takes: t = [], scripts: s = [], generation }) {
  const lib = window.catchlightBridge.library;
  takes = lib.takes = t; scripts = lib.scripts = s; current = null;
  if (generation) lib.generation = generation;
  renderTakes(); renderScripts(); renderDoc(); $('#script-heading').textContent = '';
}

// Whether this device had an account when the page loaded; a replay over one changes no data.
const freshAccount = !store.get('account', null);

async function finish() {
  // In the Mac app the account is made here: the shell stores the phrase in the Keychain, then
  // the key, then opens the encrypted library (Vault.createAccount). Nothing goes on until
  // that has worked, and the phrase is never written to localStorage.
  const lib = window.catchlightBridge?.library;
  if (lib && !lib.account) {
    try {
      const opened = await shell.createAccount(fr.restore ? fr.restoreWords : fr.words, fr.restore);
      lib.account = true;
      // The Takes the page saves next are diffed against the library the shell just opened.
      if (opened?.generation) lib.generation = opened.generation;
      if (fr.restore) fr.opened = opened;
    } catch (e) {
      ask("Couldn't secure your account on this Mac", `Nothing was saved. Try again, and if it happens again, report it with this detail: ${e}`, [['OK', null, 'cancel']]);
      return;
    }
  }
  // The prototype keeps only its own placeholder words, so Settings → Privacy phrase shows the
  // same ones. Words someone typed in could be a real phrase and are never stored: a restored
  // account shows "Phrase isn't on this device". The real phrase lives only in the Keychain.
  // An account saved with no folder has none in the shell either, whatever was picked on the way.
  if (!fr.folder) shell.forgetFolder?.();
  store.set('account', { storage: fr.storage || 'cloud', folder: fr.folder, restored: fr.restore, phrase: fr.restore || lib ? undefined : fr.words });
  // A new account: seeds after setup, none after a restore (AppModel), and no Scripts either way
  // (a restored account gets its own from the folder, D-313). A ?first-run replay over an
  // account that already exists is a look at the screens, so it leaves the Takes alone.
  // In the Mac app a restore shows what the phrase opened (Vault keeps a library it can read)
  // and saves nothing, or the page's empty list would delete it.
  if (lib && fr.restore && fr.opened) adoptLibrary(fr.opened);
  else if (freshAccount || fr.secondDevice) {
    takes = fr.restore ? [] : seedTakes(); saveTakes(); renderTakes();
    scripts = []; current = null; save(); renderScripts(); renderDoc(); $('#script-heading').textContent = '';
  }
  fr.secondDevice = false; fr.opened = null;
  layer.hidden = true; layer.innerHTML = '';
  document.body.classList.remove('first-running');
}

layer.addEventListener('click', e => {
  const tile = e.target.closest('[data-tile]'), slot = e.target.closest('[data-slot]');
  if (tile && fr.picked.length < 3) { fr.picked.push(+tile.dataset.tile); show('confirm'); checkConfirm(); return; }
  if (slot && fr.picked[+slot.dataset.slot] != null) { fr.picked.splice(+slot.dataset.slot, 1); show('confirm'); return; }
  const act = e.target.closest('[data-fr]')?.dataset.fr;
  if (!act) return;
  switch (act) {
    case 'create': fr.restore = false; show('storage'); break;
    case 'restore': show('restore'); break;
    case 'back-welcome': show('welcome'); break;
    // The shell bookmarks a folder the moment it is picked, so choosing local lets it go there too.
    case 'local': fr.storage = 'local'; fr.folder = null; shell.forgetFolder?.(); show('localWarning'); break;
    case 'cloud': fr.storage = 'cloud'; show('folder'); break;
    case 'back-storage': show('storage'); break;
    // The Mac's open panel answers later (a promise), the browser stand-in at once; a cancel keeps what was there.
    case 'pick-folder': Promise.resolve(shell.chooseFolder()).then(f => { if (f) fr.folder = f; show('folder'); }).catch(folderRefused); break;
    case 'risk': case 'folder-done': fr.words = shell.newPhrase(); show('reveal'); break;
    case 'written': newConfirm(); show('confirm'); break;
    case 'show-again': show('reveal'); break;
    case 'basics-next': if (fr.basics === 0) { fr.basics = 1; show('basics'); } else show('complete'); break;
    case 'do-restore': doRestore(); break;
    case 'connect-folder': Promise.resolve(shell.chooseFolder()).then(f => { if (!f) return; fr.folder = f; finish(); }).catch(folderRefused); break;
    case 'finish': finish(); break;
  }
});

// ---------- phrase entry, shared by first run and Settings → Second device ----------
// As PhraseEntryGrid: a space moves to the next word; a paste spreads its words across the
// fields from the one pasted into, counting only runs of letters, so "1. anchor" works;
// Return moves on, and on the last word submits.
const phraseGrid = () => `<ol class="fr-words fr-entry">${Array.from({ length: 12 }, (_, i) => `<li><span>${i + 1}</span><input type="text" data-word="${i}" aria-label="Word ${i + 1} of 12" autocomplete="off" autocapitalize="off" spellcheck="false"></li>`).join('')}</ol>`;
const phraseWords = root => [...root.querySelectorAll('[data-word]')].map(i => i.value.trim());
function wirePhraseEntry(root, changed, submit) {
  root.addEventListener('input', e => {
    const i = e.target.dataset?.word;
    if (i == null) return;
    const v = e.target.value;
    if (/\s/.test(v)) {
      const words = v.toLowerCase().match(/[a-z]+/g) || [];
      const fields = root.querySelectorAll('[data-word]');
      words.forEach((w, k) => { if (fields[+i + k]) fields[+i + k].value = w; });
      fields[Math.min(11, +i + Math.max(words.length, 1))]?.focus();
    } else e.target.value = v.toLowerCase();
    changed();
  });
  root.addEventListener('paste', e => {
    const i = e.target.dataset?.word;
    if (i == null) return;
    e.preventDefault();
    const words = (e.clipboardData.getData('text').toLowerCase().match(/[a-z]+/g) || []).slice(0, 12 - i);
    const fields = root.querySelectorAll('[data-word]');
    words.forEach((w, k) => { fields[+i + k].value = w; });
    fields[Math.min(11, +i + words.length)].focus();
    changed();
  });
  root.addEventListener('keydown', e => {
    const i = e.target.dataset?.word;
    if (i == null || e.key !== 'Enter') return;
    e.preventDefault();
    if (+i < 11) root.querySelector(`[data-word="${+i + 1}"]`).focus();
    else submit();
  });
}
wirePhraseEntry(layer, () => paintRestoreStatus(), () => { if (!layer.querySelector('[data-fr="do-restore"]').disabled) doRestore(); });

// Runs once, until an account exists. `?first-run` replays it.
if (!store.get('account', null) || new URLSearchParams(location.search).has('first-run')) {
  layer.hidden = false;
  document.body.classList.add('first-running');
  show('splash');
  setTimeout(() => { if (fr.step === 'splash') show('welcome'); }, still.matches ? 0 : 2500);
}

// Settings → Second device ends as iOS's does: the old folder is let go and the same Welcome
// back screen as a first-run restore offers to connect this account's folder (RootView).
function welcomeBack() {
  Object.assign(fr, { restore: true, storage: 'cloud', folder: null, secondDevice: true });
  document.body.classList.add('first-running');
  layer.hidden = false;
  show('restored');
}
