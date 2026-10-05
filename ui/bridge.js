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
  let takesSaves = 0, refreshWaiting = false;
  // A Take the shell couldn't read keeps its stored version, so say so rather than let the edit
  // look saved.
  const saveList = (kind, list) => (kind === 'takes' && takesSaves++, post('save', { kind, list, generation: library.generation }))
    .then(r => {
      // The shell kept a Take the page doesn't hold (both versions after a change on both sides,
      // or one the page deleted that changed elsewhere): take the library again so it shows.
      // Not when a Take was rejected: the page still holds that unsaved edit, and a refresh would
      // replace it with the stored version before the user could see it.
      if ((r?.keptBoth || r?.keptOverDelete) && !r?.rejected?.length) window.catchlightBridge.refresh().catch(e => console.error('Refreshing the Takes failed', e));
      if (r?.rejected?.length) whenNoDialog(() => ask("A Take wasn't saved", `Catchlight couldn't read ${r.rejected.length === 1 ? 'one Take' : `${r.rejected.length} Takes`}, so the last version of it is kept. Report it, with this detail: ${r.rejected.join(', ')}`, [['OK', null, 'cancel']]));
    })
    .catch(e => {
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

  window.catchlightBridge = {
    pushMenu,
    library,
    save: saveList,
    // Take the library as the shell holds it now. While a Take is held open (the editor, a
    // Focus-ring, the reminder picker) this waits for it to close, and if a save went out while the request was in flight it asks again,
    // so the list the page keeps always includes its own latest save.
    async refresh() {
      const busy = () => typeof editingTake === 'function' && editingTake();
      if (busy()) { refreshWaiting = true; return false; }
      refreshWaiting = false;
      const before = takesSaves;
      const r = await post('reload');
      if (takesSaves !== before || busy()) return this.refresh();
      library.takes = r.takes;
      library.generation = r.generation;
      replaceTakes(r.takes);
      return true;
    },
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
