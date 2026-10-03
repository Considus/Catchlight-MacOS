'use strict';
// The page's half of a native shell's bridge (the Mac's is App/Sources/ShellBridge.swift).
// Loaded before first-run.js, whose `shell` takes the methods below in place of its browser
// stand-ins. In a plain browser there is no bridge: this file does nothing and the stand-ins stay.
//
// The Mac shell gives the page two things: `window.catchlightShell`, the values the page reads
// synchronously (OS version, model), set before any script runs; and the `catchlight` message
// handler, which answers each message with a promise.
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

  window.catchlightBridge = {
    pushMenu,
    shell: {
      osVersion: () => info.osVersion,
      systemInfo: () => `${info.osName} ${info.osVersion} · ${info.model}`,
      copyText: text => post('copy', { text }),
    },
  };
})();
