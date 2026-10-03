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
  mac: { device: 'Mac', search: 'Spotlight & Siri', writingTools: true, noBackup: "Time Machine won't contain them", keptOut: 'because we deliberately keep them out of it' },
  windows: { device: 'PC', search: 'Windows Search', noBackup: "Windows Backup and File History won't contain them", keptOut: 'because we deliberately keep them out of both' },
  // Named, as Time Machine is: only Déjà Dup honours the marker the shell writes, and a general
  // "your backups" would be untrue for rsync or Borg.
  linux: { device: 'computer', search: 'Desktop search', noBackup: "Déjà Dup won't contain them", keptOut: 'because we deliberately keep them out of it' },
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
  systemInfo: () => 'macOS 26.0 · Mac16,1',
};

const fr = { step: null, storage: null, words: [], positions: [], picked: [], bank: [], basics: 0, folder: null, restore: false };
const layer = $('#first-run');

const BRAND = () => `<div class="fr-brand" aria-hidden="true"><span class="fr-iris">${iris(['note', 'task', 'remind', 'important'])}</span><span class="fr-wordmark">Catchlight</span></div>`;
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
    return `<div class="fr-error" id="fr-error" hidden>Those aren't quite right. Try again.</div>
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
  setTimeout(() => { if (fr.step === 'confirm') { fr.picked = []; show('confirm'); $('#fr-error').hidden = false; } }, 600);
}

const restoreWords = () => phraseWords(layer);
function paintRestoreStatus(error) {
  const n = restoreWords().filter(Boolean).length, status = $('#fr-status');
  status.classList.toggle('error', !!error);
  status.textContent = error || (n === 12 ? 'Ready to restore.' : `${n} of 12 words`);
  layer.querySelector('[data-fr="do-restore"]').disabled = n < 12;
}
function doRestore() {
  if (shell.phraseLooksValid(restoreWords().map(w => w.toLowerCase()))) { fr.restore = true; show('restored'); }
  else paintRestoreStatus("That doesn't look right. Check the words and try again.");
}

function finish() {
  // The prototype keeps only its own placeholder words, so Settings → Privacy phrase shows the
  // same ones. Words someone typed in could be a real phrase and are never stored: a restored
  // account shows "Phrase isn't on this device". The real phrase lives only in the Keychain.
  store.set('account', { storage: fr.storage || 'cloud', folder: fr.folder, restored: fr.restore, phrase: fr.restore ? undefined : fr.words });
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
    case 'local': fr.storage = 'local'; fr.folder = null; show('localWarning'); break;
    case 'cloud': fr.storage = 'cloud'; show('folder'); break;
    case 'back-storage': show('storage'); break;
    case 'pick-folder': fr.folder = shell.chooseFolder(); show('folder'); break;
    case 'risk': case 'folder-done': fr.words = shell.newPhrase(); show('reveal'); break;
    case 'written': newConfirm(); show('confirm'); break;
    case 'show-again': show('reveal'); break;
    case 'basics-next': if (fr.basics === 0) { fr.basics = 1; show('basics'); } else show('complete'); break;
    case 'do-restore': doRestore(); break;
    case 'connect-folder': fr.folder = shell.chooseFolder(); finish(); break;
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
