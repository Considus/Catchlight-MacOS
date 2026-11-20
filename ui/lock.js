'use strict';
// The lock screen, as the iPhone's LockView draws it. The shell locks the library once the app has
// been away for Settings → Lock after, and then opens the page with `catchlightLibrary.locked`
// (no Takes in it, nothing decrypted). The page shows this screen over the app, which stays inert
// and out of reach, until the Unlock button has the shell ask for the Mac's login and open the
// library again; the shell then reloads the page. Three states, as LockView's lockState:
//   locked     "Authenticate to open your Takes."  [Unlock]
//   unlocking  "Authenticating…"                   [Unlocking…], disabled
//   failed     the reason                          [Try Again]
// `catchlightLibrary.lockFailure` ('cancelled' or 'unopenable') opens the page in the failed state,
// and `catchlightLibrary.unlocked` marks the load right after an unlock: the lock screen is drawn
// once more, unlocking, and fades away over the app (RootView, 0.4 s). Loaded after first-run.js,
// and uses the first run's column, mark, heading and pill so the two read as one surface.

const lock = { phase: 'locked', failure: null, layer: null };

const lockMessage = (phase, failure) => phase === 'failed'
  ? (failure === 'unopenable' ? t("Your encrypted library couldn't be opened. Please restart Catchlight.") : t("Couldn't unlock. Authenticate to open your Takes."))
  : phase === 'unlocking' ? t('Authenticating…') : t('Authenticate to open your Takes.');
const lockButtonTitle = phase => phase === 'failed' ? t('Try Again') : phase === 'unlocking' ? t('Unlocking…') : t('Unlock');

function lockLayer(phase, failure) {
  const layer = document.createElement('section');
  layer.className = 'lock-screen';
  layer.innerHTML = `<div class="fr-column">${brandMark()}<div class="fr-body">
      <h2>${t('Catchlight is locked')}</h2>
      <p class="lock-message">${lockMessage(phase, failure)}</p></div></div>
    <div class="lock-dock"><button class="fr-pill primary lock-button" type="button"${phase === 'unlocking' ? ' disabled' : ''}>${lockButtonTitle(phase)}</button></div>
    <div class="sr-only lock-announce" aria-live="assertive"></div>`;
  return layer;
}

// Moves to a state: the message and the button's title crossfade (LockView, easeInOut 0.2), the
// button is disabled while unlocking, and a failure is announced (the iPhone's `.announcement`;
// nothing is announced for the others).
function setLock(phase, failure = null) {
  const layer = lock.layer, message = lockMessage(phase, failure), title = lockButtonTitle(phase);
  const text = layer.querySelector('.lock-message'), button = layer.querySelector('.lock-button');
  lock.phase = phase; lock.failure = failure;
  if (text.textContent !== message) crossfadeText(text, message, MOTION.lock);
  if (button.textContent !== title) crossfadeText(button, title, MOTION.lock);
  button.disabled = phase === 'unlocking';
  if (phase === 'failed') {
    layer.querySelector('.lock-announce').textContent = message;
    button.focus();
  }
}

// On success the shell reloads the page, so there is nothing to do here. The shell rejects with
// 'cancelled' (the login prompt was dismissed or failed) or 'unopenable' (the library itself
// couldn't be opened); anything else reads as a cancel, whose message asks to try again.
async function attemptUnlock() {
  if (lock.phase === 'unlocking') return;
  setLock('unlocking');
  try { await window.catchlightBridge.shell.unlock(); }
  catch (e) { setLock('failed', String(e?.message ?? e) === 'unopenable' ? 'unopenable' : 'cancelled'); }
}

// The shell asks for the user on its own as the app comes back (RootView's auto-unlock), and the
// lock screen shows it, as LockView does: Authenticating…, Unlocking… disabled. A failure showing
// stays: the shell only asks on its own when none is.
window.catchlightLockUnlocking = () => {
  if (lock.layer && lock.phase === 'locked') setLock('unlocking');
};

// The shell calls this once a relock has saved what was open: the page takes no more input, so
// nothing typed is lost to the closing library and no save is refused as locked.
window.catchlightRelocking = () => {
  window.catchlightRelockingNow = true;   // the menu offers no Take command from here (ui/menu.js)
  const appRoot = document.getElementById('app');
  appRoot.inert = true; appRoot.setAttribute('aria-hidden', 'true');
};

// The shell calls this next, on a relock: the lock screen fades in over the notes still shown
// (RootView, easeInOut 0.4, opacity only, so Reduce Motion keeps it) and this answers true when the
// fade ends. The shell closes the library after that and reloads the page, so the notes leave the
// page only then. The reload shows the lock screen at once (`catchlightLibrary.justLocked`).
window.catchlightLockFade = () => {
  const layer = lockLayer('locked');
  layer.id = 'lock';
  layer.setAttribute('aria-hidden', 'true'); layer.inert = true;
  document.body.append(layer);
  return layer.animate([{ opacity: 0 }, { opacity: 1 }], { ...MOTION.root, fill: 'forwards' }).finished.then(() => true, () => false);
};

const lockLibrary = window.catchlightLibrary;
if (lockLibrary?.locked) {
  const appRoot = document.getElementById('app');
  appRoot.inert = true; appRoot.setAttribute('aria-hidden', 'true');
  document.body.classList.add('locked');
  const failed = !!lockLibrary.lockFailure;
  lock.layer = lockLayer(failed ? 'failed' : 'locked', lockLibrary.lockFailure);
  lock.layer.id = 'lock';
  lock.phase = failed ? 'failed' : 'locked'; lock.failure = lockLibrary.lockFailure ?? null;
  document.body.append(lock.layer);
  lock.layer.addEventListener('click', e => { if (e.target.closest('.lock-button')) attemptUnlock(); });
  if (failed) lock.layer.querySelector('.lock-announce').textContent = lockMessage('failed', lock.failure);
  lock.layer.querySelector('.lock-button').focus();
  // The first thing painted, so it fades in from the plain ground (RootView, easeInOut 0.4).
  // After a faded relock it is already what the user sees: no second fade.
  if (!lockLibrary.justLocked) lock.layer.animate([{ opacity: 0 }, { opacity: 1 }], MOTION.root);
} else if (lockLibrary?.unlocked) {
  // The page is the app, just unlocked: the lock screen, unlocking, fades away over it. A picture
  // only, so hidden from the screen reader with nothing to press.
  const copy = lockLayer('unlocking');
  copy.classList.add('lock-leaving');
  copy.setAttribute('aria-hidden', 'true'); copy.inert = true;
  copy.querySelector('.lock-announce').remove();
  document.body.append(copy);
  copy.animate([{ opacity: 1 }, { opacity: 0 }], MOTION.root).finished.then(() => copy.remove(), () => copy.remove());
}
