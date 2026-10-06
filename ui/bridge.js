'use strict';
// The page's half of a native shell's bridge (the Mac's is App/Sources/ShellBridge.swift).
// Loaded first, before app.js reads the library through its store, and first-run.js's `shell`
// takes the methods below in place of its browser stand-ins. In a plain browser there is no bridge: this file does nothing and the stand-ins stay.
//
// The Mac shell gives the page three things, the first two set before any script runs:
// `window.catchlightShell`, the values the page reads synchronously (OS version, model);
// `window.catchlightLibrary`, the account state and the decrypted Takes and Scripts, which the
// page's store reads in place of localStorage (app.js); and the `catchlight` message handler,
// which answers each message with a promise.
(() => {
  const handler = window.webkit?.messageHandlers?.catchlight, info = window.catchlightShell;
  if (!handler || !info) return;
  const post = (cmd, data = {}) => handler.postMessage({ cmd, ...data });
  document.documentElement.classList.add('in-shell');   // app.css: the real traffic lights replace the drawn ones

  // The native menu bar. AppKit checks an item synchronously as a menu opens or its key is
  // pressed, so the page pushes its model whenever it may have changed and the shell reads the
  // latest push: soon after anything that can change focus, selection or state, and on a 250 ms
  // poll for everything else (a timer, a repaint). Only a model that differs is sent.
  let sent = '', timer = 0;
  const pushMenu = force => {
    if (!window.catchlightMenu) return;   // menu.js loads last
    const model = JSON.stringify(catchlightMenu.model());
    if (model === sent && !force) return;
    sent = model;
    post('menu', { model });
  };
  const soon = () => { clearTimeout(timer); timer = setTimeout(pushMenu, 30); };
  for (const type of ['focusin', 'focusout', 'selectionchange', 'input', 'change', 'keyup', 'mouseup'])
    document.addEventListener(type, soon, true);
  setInterval(pushMenu, 250);

  // The toolbar is the title bar: dragging its empty space moves the window, and a double-click
  // there zooms it, as the system setting says. Its controls keep their clicks.
  document.addEventListener('mousedown', e => {
    if (e.button !== 0 || !e.target.closest?.('.toolbar')) return;
    if (e.target.closest('button, a, input, select, textarea, [role], .popover, .seg')) return;
    post(e.detail === 2 ? 'titlebarDoubleClick' : 'dragWindow');
  });

  // Links open in the default browser or mail app, never in the window.
  window.open = url => { post('openURL', { url: new URL(url, location.href).href }); return null; };

  // The library. A save sends the whole list; the shell writes what changed and keeps the rest.
  // Saves go in order, one message each, so the last one sent is the one that stands. A Takes
  // save names the snapshot its list came from (`generation`), and the shell diffs against that
  // snapshot, so a Take sync added since is never read as one the page deleted (Library.swift).
  const library = window.catchlightLibrary;
  let saves = 0, refreshWaiting = false;
  // A Scripts save that failed or was refused leaves an edit only the page holds, so a refresh
  // keeps the page's Scripts rather than replace them with the stored ones (Greptile on #55).
  let scriptsUnsaved = false, lastScriptsSave = Promise.resolve();
  // The snapshot the page's Scripts came from, when a refresh kept them (null: the Takes' one).
  // Kept Scripts are diffed against their own snapshot, or a Script sync added meanwhile would
  // read as one the user deleted (Greptile on #55).
  let scriptsGeneration = null;
  // A Take the shell couldn't read keeps its stored version, so say so rather than let the edit
  // look saved.
  // Scripts sync only once the shell says they do (SyncService.syncScriptsKey).
  const sendList = (kind, list) => (saves++, (kind === 'takes' || library.syncScripts) && syncSoon(), post('save', { kind, list, generation: kind === 'scripts' ? scriptsGeneration ?? library.generation : library.generation }))
    .then(r => {
      if (kind === 'scripts') scriptsUnsaved = !!r?.rejected?.length;
      // Kept Scripts saved at last: take the library again now, so their snapshot is let go
      // before the Library drops it (it keeps eight) and refuses every save after (Claude review).
      if (kind === 'scripts' && !scriptsUnsaved && scriptsGeneration != null) window.catchlightBridge.refresh().catch(e => console.error('Refreshing the Scripts failed', e));
      // The shell kept a Take the page deleted that changed elsewhere: take the library again
      // so it shows. (A Take changed here and by sync goes to the conflict screen instead.)
      // Not when a Take was rejected: the page still holds that unsaved edit, and a refresh would
      // replace it with the stored version before the user could see it.
      if (r?.conflicts) window.loadConflicts?.();   // a Take changed here and by sync: the choice screen
      if (r?.keptOverDelete && !r?.rejected?.length) window.catchlightBridge.refresh().catch(e => console.error('Refreshing the Takes failed', e));
      const [one, many] = kind === 'scripts' ? ['Script', 'Scripts'] : ['Take', 'Takes'];
      if (r?.rejected?.length) whenNoDialog(() => ask(`A ${one} wasn't saved`, `Catchlight couldn't read ${r.rejected.length === 1 ? `one ${one}` : `${r.rejected.length} ${many}`}, so the last version of it is kept. Report it, with this detail: ${r.rejected.join(', ')}`, [['OK', null, 'cancel']]));
    })
    .catch(e => {
      if (kind === 'scripts') scriptsUnsaved = true;
      console.error(`Saving ${kind} failed`, e);
      // A refused save must never look saved: say so, with what to do. If another dialog is
      // open (a delete confirmation, say), the warning waits for it rather than replacing it.
      if (refusalShown) return;
      refusalShown = true;
      const warn = () => {
        ask("That change wasn't saved", /locked/.test(String(e?.message ?? e))
          ? 'Your Takes are locked on this Mac, so nothing more can be saved now. Quit Catchlight, open it again, and choose I already use Catchlight with your current Privacy phrase. Everything saved before this is safe.'
          : `Catchlight couldn't save it. Quit and open Catchlight again, and if this keeps happening, report it with this detail: ${e?.message ?? e}`,
          [['OK', null, 'cancel']]);
        alertBox.addEventListener('close', () => { refusalShown = false; }, { once: true });   // however it is dismissed
      };
      whenNoDialog(warn);
    });
  const saveList = (kind, list) => {
    const done = sendList(kind, list);
    if (kind === 'scripts') lastScriptsSave = done;
    return done;
  };
  // The page has one dialog (ask() in takes.js), and a second ask() would replace whatever it is
  // showing, a delete confirmation say. A warning from a save waits for it to close instead.
  const whenNoDialog = show => {
    if (!alertBox.open) return show();
    alertBox.addEventListener('close', () => setTimeout(() => whenNoDialog(show)), { once: true });
  };
  let refusalShown = false;
  // The shell couldn't read the library: say so, rather than show an empty Catchlight that
  // looks as if everything has gone. The shell refuses every save until it can read it.
  if (library?.unreadableScripts) addEventListener('load', () => ask(`${library.unreadableScripts === 1 ? 'A Script' : `${library.unreadableScripts} Scripts`} couldn't be opened`,
    'It is kept on this Mac as it was, nothing has been deleted, and the others are fine. Report it so it can be looked at.', [['OK', null, 'cancel']]));
  if (library?.loadError) addEventListener('load', () => ask("Catchlight couldn't read your Takes",
    `Nothing has been changed or deleted, and nothing you do now will be saved. Quit and open Catchlight again, and if this keeps happening, report it with this detail: ${library.loadError}`,
    [['OK', null, 'cancel']]));

  // The shell is the authority on the sync folder: the page's account record shows the folder
  // the shell can actually open, or none, so a deleted folder or a lost bookmark never looks connected.
  try {
    const account = JSON.parse(localStorage.getItem('cl.account'));
    if (account && (account.folder ?? null) !== (info.folder ?? null)) {
      localStorage.setItem('cl.account', JSON.stringify({ ...account, folder: info.folder ?? null }));
    }
  } catch { /* no account record yet, or storage unavailable */ }

  // Sync (M3). When to sync is decided here, where the sync setting lives; the shell runs one pass
  // at a time and answers a request during a pass as skipped. As the iPhone does: at launch, a
  // few seconds after a save, when the window comes forward (at most once a minute), every 15
  // minutes, and on Sync Now. Manual syncs only on Sync Now; Disabled never.
  // `again`: a pass was asked for while one ran (a save written once the running pass ended, say),
  // so one more pass follows, or that save would wait for the next trigger to reach the cloud.
  // `following`: the promise of that follow-up pass, so whoever asked (Sync Now) waits for it.
  let syncing = null, again = null, following = null, saveTimer = 0, lastFocusSync = 0;
  const syncMode = () => (typeof settings !== 'undefined' && settings.syncMode) || 'automatic';
  const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;
  function sync(trigger) {
    if (!library?.account || !store.get('account', {})?.folder) return Promise.resolve({ skipped: true });
    const mode = syncMode();
    if (mode === 'disabled' || (mode === 'manual' && trigger !== 'manual')) return Promise.resolve({ skipped: true });
    if (syncing) {
      again = again || trigger;
      // `syncing` is the promise after `.finally`, which has started the follow-up by the time it
      // settles, so this resolves with the follow-up's own result.
      following = following || syncing.then(() => followUp);
      return following;
    }
    syncing = post('sync', { trigger })
      .then(async r => {
        // The iPhone's words (Notice.message), so both apps say the same thing.
        if (r?.error) notice(r.error, 'sync');
        if (r?.applied || r?.deleted) await window.catchlightBridge.refresh().catch(e => console.error('Refreshing the Takes failed', e));
        if (r?.conflicts) window.loadConflicts?.();
        if (r?.newConflicts) {
          const scripts = r.newConflictScripts || 0, takes = r.newConflicts - scripts;
          const what = [takes && plural(takes, 'Take', 'Takes'), scripts && plural(scripts, 'Script', 'Scripts')].filter(Boolean).join(' and ');
          notice(`${what} changed on another device.`, 'conflict');
        }
        if (r?.newUnverified) notice(`${plural(r.newUnverified, 'Take', 'Takes')} couldn't be verified and need a choice.`, 'conflict');
        if (r?.quarantined) notice(`${plural(r.quarantined, 'Take', 'Takes')} couldn't be verified and were skipped.`, 'quarantine');
        if (r?.heldBack) notice(`${plural(r.heldBack, 'Take', 'Takes')} not re-uploaded. This device was away too long to rule out deletion elsewhere. Edit a Take to sync it again.`, 'sync');
        return r;
      })
      .catch(e => { console.error('Sync failed', e); return { error: String(e?.message ?? e) }; })
      .finally(() => {
        syncing = null;
        if (again) { const t = again; again = null; followUp = sync(t); }
        following = null;
      });
    return syncing;
  }
  let followUp = Promise.resolve({ skipped: true });
  function syncSoon() { clearTimeout(saveTimer); saveTimer = setTimeout(() => sync('save'), 5000); }
  addEventListener('load', () => setTimeout(() => sync('launch'), 1000));
  addEventListener('focus', () => { if (Date.now() - lastFocusSync > 60_000) { lastFocusSync = Date.now(); sync('focus'); } });
  setInterval(() => sync('timer'), 15 * 60_000);

  window.catchlightBridge = {
    pushMenu,
    library,
    save: saveList,
    // Take the library (Takes and Scripts) as the shell holds it now. While a Take is held open (the editor, a
    // Focus-ring, the reminder picker) this waits for it to close, and if a save went out while the request was in flight it asks again,
    // so the list the page keeps always includes its own latest save.
    async refresh() {
      const busy = () => typeof editingTake === 'function' && editingTake();
      if (busy()) { refreshWaiting = true; return false; }
      refreshWaiting = false;
      // A Script edit still waiting for its save goes first, so the list that comes back has it.
      if (typeof scriptSavePending !== 'undefined' && scriptSavePending) save();
      await lastScriptsSave;   // so a refused save is known before the Scripts are replaced
      const before = saves;
      const r = await post('reload');
      // A Script typed into while the answer was on its way: save it, then ask again.
      if (saves !== before || busy() || (typeof scriptSavePending !== 'undefined' && scriptSavePending)) return this.refresh();
      library.takes = r.takes;
      if (scriptsUnsaved) scriptsGeneration ??= library.generation;
      else { scriptsGeneration = null; library.scripts = r.scripts; replaceScripts(r.scripts); }
      library.generation = r.generation;
      replaceTakes(r.takes);
      return true;
    },
    sync,
    conflicts: () => post('conflicts'),
    // The item comes from the other list, so it names that list's snapshot.
    changeKind: (item, to) => post('changeKind', { item, to, generation: to === 'takes' ? scriptsGeneration ?? library.generation : library.generation })
      .then(r => { if (r?.conflicts) window.loadConflicts?.(); return r; }),
    resolveConflict: (id, choice) => post('resolveConflict', { id, choice }),
    afterEdit() { if (refreshWaiting) this.refresh().catch(e => console.error('Refreshing the Takes failed', e)); },
    // The shell calls this as the app quits or the window closes: a Take being edited is saved
    // as a click outside it would save it, and the Script editor's pending (debounced) save goes
    // now. It answers once the shell has written everything sent before it.
    async flush() {
      if (typeof draft !== 'undefined' && draft) commitEdit();
      if (typeof script === 'function' && script()) save();
      await post('ping');
      return true;
    },
    shell: {
      osVersion: () => info.osVersion,
      // The sync folder: the Mac's open panel. The answer is the path to show, or null on cancel;
      // the bookmark that gives access stays in the shell (SyncFolder.swift).
      chooseFolder: () => post('chooseFolder'),
      forgetFolder: () => post('forgetFolder'),
      systemInfo: () => `${info.osName} ${info.osVersion} · ${info.model}`,
      copyText: text => post('copy', { text }),
      ...(library && {
        // The phrase comes from Core (BIP-39 English, 12 different words), made before the page
        // loaded, and the shell checks one typed in against the list and its checksum.
        newPhrase: () => library.newPhrase || [],
        phraseLooksValid: words => post('validatePhrase', { words }),
        createAccount: (words, restored) => post('createAccount', { words, restored }),
        replaceAccount: words => post('replaceAccount', { words }),
        revealPhrase: () => post('revealPhrase'),
        eraseEverything: () => post('eraseEverything'),
      }),
    },
  };
})();
