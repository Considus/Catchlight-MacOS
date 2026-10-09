'use strict';
// Reminders, as the iPhone's ReminderPickerSheet and TimeReminder (As-Built, D-274): a time,
// or a place, never both (owner 2026-06-24). A time can be all-day, silent, and repeat; a
// repeating reminder is never done, marking it done moves it to its next occurrence. Loaded
// after settings.js and before takes.js, whose cards read the labels here on first render.
// The map, place search and current location are the shell's (MapKit on the Mac); here they
// are stand-ins.
//
// A reminder on a Take is one of:
//   { kind: 'time', when, done, allDay, notify, repeat, weekdays, anchorDay? }   weekdays: 1 = Sunday … 7
//     anchorDay is set only while a monthly or annual repeat sits on a clamped day, so a series
//     on the 31st returns to the 31st after February (D-329).
//   { kind: 'place', name, mode: 'arrive' | 'leave', radius, notify, done }
// A reminder written before kinds existed ({ when, done }) is a time.

const isTimeR = r => !!r && r.kind !== 'place';
// A place named "Current location" is stored in English, as the iPhone stores it: its address
// lookup replaces only that exact name (LocationEditor.shouldAdoptGeocodedName). Shown translated.
const CURRENT_LOCATION = 'Current location';
const placeName = name => name === CURRENT_LOCATION ? t('Current location') : name;
const storedPlaceName = shown => shown === t('Current location') ? CURRENT_LOCATION : shown;
// The Mac app can't make a place reminder yet: Core needs coordinates and the Mac has no map
// (owner 2026-10-03, places on desktop wait until asked for). One made on the iPhone still
// opens here, with its name, mode and radius editable.
const placeOffered = () => !window.catchlightBridge?.library || !!rs.place;
const isPlaceR = r => !!r && r.kind === 'place';
const repeats = r => isTimeR(r) && !!r.repeat && r.repeat !== 'none';
// English, for the exported Markdown (Core's format); REPEAT_SHOWN is what the screen reads.
const REPEAT_LABEL = { hourly: 'Hourly', daily: 'Daily', weekly: 'Weekly', monthly: 'Monthly', annually: 'Annually' };
const REPEAT_SHOWN = { hourly: t('Hourly'), daily: t('Daily'), weekly: t('Weekly'), monthly: t('Monthly'), annually: t('Annually') };
// Dates, times and weekday names in the page's language (L10N in i18n.js); [] is the viewer's own.
const DATES = L10N.dateLocale([]);
// The calendar's first day, per language as the iPhone's ReminderPickerSheet.firstWeekday: Monday
// in most of Europe and Turkey, Sunday in English, Brazilian Portuguese and the Asian languages.
const MONDAY_FIRST = new Set(['de', 'es', 'it', 'nl', 'pt-PT', 'pl', 'sv', 'da', 'nb', 'fi', 'tr', 'fr']);
const FIRST_WEEKDAY = MONDAY_FIRST.has(L10N.lang) ? 1 : 0;   // 0 Sunday, 1 Monday
const lastDay = (y, m) => new Date(y, m + 1, 0).getDate();

// The occurrence after `from`. Monthly and annual repeats keep the series' day, moving to the
// last day of a shorter month, so the 31st becomes the 30th or the 28th and then the 31st again.
function nextOccurrence(r, from) {
  const d = new Date(from), day = r.anchorDay ?? new Date(r.when).getDate();
  switch (r.repeat) {
    case 'hourly': d.setHours(d.getHours() + 1); return d;
    case 'daily': d.setDate(d.getDate() + 1); return d;
    case 'weekly':
      if (!r.weekdays?.length) { d.setDate(d.getDate() + 7); return d; }
      do d.setDate(d.getDate() + 1); while (!r.weekdays.includes(d.getDay() + 1));
      return d;
    case 'monthly': { const y = d.getFullYear(), m = d.getMonth() + 1; d.setDate(1); d.setMonth(m); d.setDate(Math.min(day, lastDay(d.getFullYear(), d.getMonth()))); return d; }
    case 'annually': { d.setDate(1); d.setFullYear(d.getFullYear() + 1); d.setDate(Math.min(day, lastDay(d.getFullYear(), d.getMonth()))); return d; }
  }
  return d;
}
// effectiveNextDue: the stored time while it is ahead, otherwise the next occurrence after now.
function nextDue(r) {
  let d = new Date(r.when);
  if (!repeats(r)) return d;
  for (let n = 0; d < new Date() && n < 20000; n++) d = nextOccurrence(r, d);
  return d;
}

// "Today", "Tomorrow", "Yesterday", or the medium date ("3 Oct 2026", "Oct 3, 2026"), in the
// viewer's locale: iOS's medium date style with relative formatting.
const dayOffset = d => {
  const today = new Date(); today.setHours(0, 0, 0, 0);
  return Math.round((new Date(d).setHours(0, 0, 0, 0) - today) / 864e5);
};
function dayWord(d) {
  return { '-1': t('Yesterday'), 0: t('Today'), 1: t('Tomorrow') }[dayOffset(d)] ?? d.toLocaleDateString(DATES, { dateStyle: 'medium' });
}
// The day and the time as one phrase, each a whole sentence: "Tomorrow at 09:00", or a date with
// its time in the language's own pattern.
function dayAndTime(d) {
  const time = d.toLocaleTimeString(DATES, { timeStyle: 'short' });
  const near = { '-1': t('Yesterday at %@', time), 0: t('Today at %@', time), 1: t('Tomorrow at %@', time) }[dayOffset(d)];
  if (near) return near;
  return L10N.lang === 'en' ? `${dayWord(d)} at ${time}` : d.toLocaleString(DATES, { dateStyle: 'medium', timeStyle: 'short' });
}

// The line on a card: "Tomorrow at 09:00 · Daily", the date alone when all-day, or
// "Home · On arrival". The weekdays of a custom repeat are not shown, as on iOS.
function reminderLine(r) {
  if (isPlaceR(r)) return `${placeName(r.name) || t('Location')} · ${r.mode === 'leave' ? t('On leaving') : t('On arrival')}`;
  const d = nextDue(r);
  const when = r.allDay ? dayWord(d) : dayAndTime(d);
  return repeats(r) ? `${when} · ${REPEAT_SHOWN[r.repeat]}` : when;
}
const ICON_BELL_SLASH = '<svg viewBox="0 0 24 24"><path d="M6 16V11a6 6 0 0 1 9.5-4.9M18 11v5l1.5 2h-15M10 20.5h4M4 4l16 16"/></svg>';
const ICON_PIN = '<svg viewBox="0 0 24 24"><path d="M12 21s-6-5.6-6-11a6 6 0 0 1 12 0c0 5.4-6 11-6 11z"/><circle cx="12" cy="10" r="2.2"/></svg>';
const reminderMeta = r => `<div class="meta">${isPlaceR(r) ? ICON_PIN : ICON_CLOCK}${r.notify === false ? ICON_BELL_SLASH : ICON_BELL}${esc(reminderLine(r))}</div>`;

// Marking a repeating reminder done moves it to the following occurrence; the series goes on.
// A monthly or annual series that lands on a clamped day remembers its own day (D-329).
function advanceRepeat(r) {
  const next = nextOccurrence(r, nextDue(r)), seriesDay = r.anchorDay ?? new Date(r.when).getDate();
  r.when = next.toISOString(); r.done = false;
  if ((r.repeat === 'monthly' || r.repeat === 'annually') && next.getDate() !== seriesDay) r.anchorDay = seriesDay;
  else delete r.anchorDay;
}

// ---------- the picker ----------
const rsheet = document.createElement('section');
rsheet.className = 'settings-sheet reminder-sheet'; rsheet.id = 'reminder-sheet'; rsheet.hidden = true;
document.body.append(rsheet);

let reminderFor = null, reminderAfter = null, reminderCancel = null, rs = null;
const pad2 = n => String(n).padStart(2, '0');
const hhmm = d => `${pad2(d.getHours())}:${pad2(d.getMinutes())}`;

// Open the picker for a Take. `after` runs on Done; `onCancel` on Cancel (from the Focus-ring,
// Cancel removes the reminder just added; from the editor bar it changes nothing).
function openReminder(t, after, onCancel) {
  reminderFor = t; reminderAfter = after; reminderCancel = onCancel || null;
  const r = t.reminder;
  // A new reminder starts at Settings → Default timing from now.
  const start = isTimeR(r) ? new Date(r.when) : new Date(Date.now() + settings.reminderHours * 36e5);
  rs = {
    tab: isPlaceR(r) ? 'place' : 'time', date: start, time: hhmm(start), quick: null,
    allDay: isTimeR(r) ? !!r.allDay : false, notify: isTimeR(r) ? r.notify !== false : true,
    repeat: isTimeR(r) ? r.repeat || 'none' : 'none', weekdays: isTimeR(r) ? [...(r.weekdays || [])] : [],
    place: isPlaceR(r) ? { ...r } : null, query: '',
    view: new Date(start.getFullYear(), start.getMonth(), 1),
  };
  reminderReturn = document.activeElement;
  rsheet.hidden = false;
  paintReminder();
  requestAnimationFrame(() => rsheet.classList.add('open'));
  rsheet.querySelector('button, [tabindex="0"], input, select')?.focus();
}
// Closing gives focus back: to the editor line the caret was on (DailiesView.closeReminderEditor),
// else to whatever opened the picker, if it is still on the page.
let reminderReturn = null;
function closeReminder() {
  const wasOpen = !!reminderFor;
  rsheet.classList.remove('open');
  rsheet.hidden = true; rsheet.innerHTML = '';
  reminderFor = reminderAfter = reminderCancel = rs = null;
  const back = reminderReturn; reminderReturn = null;
  if (!wasOpen) return;   // endEdit tidies up a picker that wasn't open: nothing to hand back
  if (focusRing) { if (back?.isConnected) back.focus(); return; }   // back to the Remind Mark
  if (draft) restoreCaret(); else if (back?.isConnected) back.focus();
  window.catchlightBridge?.afterEdit();   // a refresh that waited for the picker goes now
}
const cancelReminder = () => { const c = reminderCancel; closeReminder(); c && c(); };

const QUICK = [['evening', t('This evening')], ['tomorrow', t('Tomorrow')], ['weekend', t('This weekend')], ['nextweek', t('Next week')]];
function quickDate(k) {
  const now = new Date(), d = new Date(now);
  if (k === 'evening') { d.setHours(20, 0, 0, 0); if (d <= now) d.setDate(d.getDate() + 1); }
  else if (k === 'tomorrow') { d.setDate(d.getDate() + 1); d.setHours(9, 0, 0, 0); }
  else if (k === 'weekend') {
    d.setHours(9, 0, 0, 0);
    const wd = now.getDay();
    if (!((wd === 6 || wd === 0) && d > now)) d.setDate(d.getDate() + ((6 - wd + 7) % 7 || 7));
  } else if (k === 'nextweek') { d.setDate(d.getDate() + ((8 - now.getDay()) % 7 || 7)); d.setHours(9, 0, 0, 0); }
  return d;
}
const INTERVALS = [['hourly', t('Hourly')], ['daily', t('Daily')], ['weekly', t('Weekly')], ['weekdays', t('Every weekday')], ['weekend', t('Every weekend')], ['custom', t('Custom')], ['monthly', t('Monthly')], ['annually', t('Annually')]];
function intervalOf() {
  if (rs.repeat !== 'weekly') return rs.repeat;
  const w = [...rs.weekdays].sort().join();
  return !w ? 'weekly' : w === '2,3,4,5,6' ? 'weekdays' : w === '1,7' ? 'weekend' : 'custom';
}
function setInterval_(v) {
  if (['weekdays', 'weekend', 'custom'].includes(v)) {
    rs.repeat = 'weekly';
    rs.weekdays = v === 'weekdays' ? [2, 3, 4, 5, 6] : v === 'weekend' ? [1, 7] : [rs.date.getDay() + 1];
  } else { rs.repeat = v; rs.weekdays = []; }
}

const rrow = (icon, label, control) => `<label class="srow">${icon}<span class="srow-label">${label}</span>${control.replace('aria-label="@"', `aria-label="${label}"`)}</label>`;
const rselect = (id, options, value) => `<span class="srow-value">${(options.find(o => o[0] === value) || [, t('Select')])[1]}</span>${UPDOWN}<select data-r="${id}" aria-label="@">${value == null ? `<option value="" selected disabled>${t('Select')}</option>` : ''}${options.map(([v, l]) => `<option value="${v}"${v === value ? ' selected' : ''}>${l}</option>`).join('')}</select>`;
const rswitch = (id, on) => `<input type="checkbox" role="switch" class="srow-switch" data-r="${id}"${on ? ' checked' : ''}>`;
const RI = k => `<svg class="srow-icon" viewBox="0 0 24 24" aria-hidden="true">${SI[k] || k}</svg>`;

function calendarHtml() {
  const v = rs.view, y = v.getFullYear(), m = v.getMonth(), first = (new Date(y, m, 1).getDay() - FIRST_WEEKDAY + 7) % 7, days = lastDay(y, m);
  const sel = rs.date, today = new Date();
  const heads = [...Array(7)].map((_, i) => new Date(2026, 1, 1 + FIRST_WEEKDAY + i).toLocaleDateString(DATES, { weekday: 'narrow' }));   // 1 Feb 2026 is a Sunday
  let cells = '';
  for (let i = 0; i < first; i++) cells += '<span></span>';
  for (let d = 1; d <= days; d++) {
    const isSel = sel.getFullYear() === y && sel.getMonth() === m && sel.getDate() === d;
    const isToday = today.getFullYear() === y && today.getMonth() === m && today.getDate() === d;
    cells += `<button type="button" class="rday${isSel ? ' on' : ''}${isToday ? ' today' : ''}" data-day="${d}" aria-label="${new Date(y, m, d).toLocaleDateString(DATES, { dateStyle: 'full' })}"${isSel ? ' aria-pressed="true"' : ''}>${d}</button>`;
  }
  return `<div class="rcal"><div class="rcal-head"><button type="button" data-r="prev" aria-label="${esc(t('Previous month'))}">‹</button>
    <span>${v.toLocaleDateString(DATES, { month: 'long', year: 'numeric' })}</span><button type="button" data-r="next" aria-label="${esc(t('Next month'))}">›</button></div>
    <div class="rcal-grid">${heads.map(h => `<i>${h}</i>`).join('')}${cells}</div></div>`;
}

function timeTab() {
  const showDays = rs.repeat === 'weekly' && rs.weekdays.length;
  return `<div class="sgroup">${rrow(RI('<path d="M6 19l9-9M15 4v2M19 8h2M17.5 5.5l1.5-1.5M12 6l1 1M17 11l1 1"/>'), t('Quick set'), rselect('quick', QUICK, rs.quick))}</div>
    ${rs.allDay ? '' : `<div class="sgroup">${rrow(RI('clock'), t('Time'), `<input type="time" class="rtime" data-r="time" value="${rs.time}" aria-label="${esc(t('Time'))}">`)}</div>`}
    <div class="sgroup">
      ${rrow(RI('calendar'), t('All-day'), rswitch('allDay', rs.allDay))}
      ${rrow(RI(rs.notify ? 'bell' : '<path d="M6 16V11a6 6 0 0 1 9.5-4.9M18 11v5l1.5 2h-15M10 20.5h4M4 4l16 16"/>'), t('Notify'), rswitch('notify', rs.notify))}
      ${rrow(RI('<path d="M17 3l3 3-3 3M4 11V9a3 3 0 0 1 3-3h13M7 21l-3-3 3-3M20 13v2a3 3 0 0 1-3 3H4"/>'), t('Repeat'), rswitch('repeat', rs.repeat !== 'none'))}
      ${rs.repeat !== 'none' ? rrow(RI('clock'), t('Interval'), rselect('interval', INTERVALS, intervalOf())) : ''}
      ${showDays ? `<div class="rdays">${[1, 2, 3, 4, 5, 6, 7].map(i => (i - 1 + FIRST_WEEKDAY) % 7 + 1).map(w => { const d = new Date(2026, 1, w); return `<button type="button" class="rwd${rs.weekdays.includes(w) ? ' on' : ''}" data-wd="${w}" aria-pressed="${rs.weekdays.includes(w)}" aria-label="${d.toLocaleDateString(DATES, { weekday: 'long' })}">${d.toLocaleDateString(DATES, { weekday: 'narrow' })}</button>`; }).join('')}</div>` : ''}
    </div>
    ${calendarHtml()}`;
}

function placeTab() {
  const p = rs.place;
  return `<div class="rsearch"><svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="10.5" cy="10.5" r="5.5"/><path d="M15 15l4.5 4.5"/></svg>
      <input type="search" data-r="query" placeholder="${esc(t('Search a place or address'))}" aria-label="${esc(t('Search a place or address'))}" value="${esc(rs.query)}" autocomplete="off"></div>
    <button type="button" class="fr-pill rcurrent" data-r="current">${ICON_PIN} ${t('Use current location')}</button>
    ${p ? `<div class="rmap" aria-hidden="true"><svg viewBox="0 0 300 160" preserveAspectRatio="xMidYMid slice"><defs><pattern id="rgrid" width="24" height="24" patternUnits="userSpaceOnUse"><path d="M24 0H0V24" fill="none" stroke="currentColor" stroke-opacity=".12"/></pattern></defs>
        <rect width="300" height="160" fill="url(#rgrid)"/><circle cx="150" cy="80" r="${18 + p.radius / 10}" fill="var(--accent)" fill-opacity=".18" stroke="var(--accent)" stroke-width="2"/>
        <g transform="translate(138 52)">${ICON_PIN.replace('<svg viewBox="0 0 24 24">', '<svg width="24" height="24" viewBox="0 0 24 24" style="color:var(--accent)">')}</g></svg></div>
      <div class="sgroup">
        <div class="srow"><div class="seg small" role="radiogroup"><button type="button" role="radio" data-r="arrive" aria-checked="${p.mode !== 'leave'}">${t('When I arrive')}</button><button type="button" role="radio" data-r="leave" aria-checked="${p.mode === 'leave'}">${t('When I leave')}</button></div></div>
        ${rrow(RI('<circle cx="12" cy="12" r="8" stroke-dasharray="3 2.5"/>'), t('Radius'), rselect('radius', [['100', '100 m'], ['150', '150 m'], ['250', '250 m'], ['500', '500 m']], String(p.radius)))}
        ${rrow(RI(p.notify ? 'bell' : '<path d="M6 16V11a6 6 0 0 1 9.5-4.9M18 11v5l1.5 2h-15M10 20.5h4M4 4l16 16"/>'), t('Notify'), rswitch('placeNotify', p.notify))}
        ${rrow(`<span class="srow-icon">${ICON_PIN}</span>`, t('Place'), `<input type="text" class="rname" data-r="name" placeholder="${esc(t('e.g. Home'))}" value="${esc(placeName(p.name) || '')}" aria-label="${esc(t('Place name'))}">`)}
      </div>
      ${p.radius === 100 ? `<p class="sgroup-foot">${PLATFORM.text.tightRadius()}</p>` : ''}
      ${p.notify ? '' : `<p class="sgroup-foot">${t('Silent. Keeps the place on the Take, with no alert when you arrive or leave.')}</p>`}` : ''}`;
}

function paintReminder() {
  const scroll = rsheet.querySelector('.sheet-scroll')?.scrollTop || 0;
  const placeless = rs.tab === 'place' && !rs.place;
  rsheet.innerHTML = `<div class="sheet-panel" role="dialog" aria-modal="true" aria-label="${esc(t('Reminder'))}">
    <div class="sheet-bar rbar"><button type="button" class="slink" data-r="cancel">${t('Cancel')}</button><span class="sheet-title">${t('Reminder')}</span>
      <button type="button" class="slink strong" data-r="done"${placeless ? ' disabled' : ''}>${t('Done')}</button></div>
    <div class="sheet-scroll rbody">
      ${placeOffered() ? `<div class="seg rtabs" role="radiogroup"><button type="button" role="radio" data-r="tab-time" aria-checked="${rs.tab === 'time'}">${t('Time')}</button><button type="button" role="radio" data-r="tab-place" aria-checked="${rs.tab === 'place'}">${t('Place')}</button></div>` : ''}
      ${rs.tab === 'time' ? timeTab() : placeTab()}
    </div></div>`;
  rsheet.querySelector('.sheet-scroll').scrollTop = scroll;
}

function doneReminder() {
  const t = reminderFor;
  if (rs.tab === 'place') {
    if (!rs.place) return;
    // An edit keeps a place reminder's done state; a new one starts not done.
    t.reminder = { kind: 'place', name: rs.place.name || '', mode: rs.place.mode, radius: rs.place.radius, notify: rs.place.notify, done: isPlaceR(t.reminder) ? !!t.reminder.done : false };
  } else {
    const d = new Date(rs.date);
    if (rs.allDay) d.setHours(9, 0, 0, 0);   // an all-day reminder fires at 09:00
    else { const [h, m] = rs.time.split(':').map(Number); d.setHours(h, m, 0, 0); }
    const prev = t.reminder;
    t.reminder = { kind: 'time', when: d.toISOString(), done: false, allDay: rs.allDay, notify: rs.notify, repeat: rs.repeat, weekdays: rs.repeat === 'weekly' ? [...rs.weekdays].sort() : [] };
    // Re-saving the same day and repeat keeps the series' day, even at a new time; a new day starts afresh.
    if (isTimeR(prev) && prev.anchorDay != null && prev.repeat === t.reminder.repeat && new Date(prev.when).toDateString() === d.toDateString()) t.reminder.anchorDay = prev.anchorDay;
  }
  const after = reminderAfter; closeReminder(); after && after();
}

rsheet.addEventListener('click', e => {
  if (e.target === rsheet) { cancelReminder(); return; }
  const b = e.target.closest('[data-r], [data-day], [data-wd]');
  if (!b || b.tagName === 'SELECT' || b.tagName === 'INPUT') return;
  const k = b.dataset.r;
  if (k === 'cancel') return cancelReminder();
  if (k === 'done') return doneReminder();
  if (k === 'tab-time' || k === 'tab-place') rs.tab = k.slice(4);
  else if (k === 'prev' || k === 'next') rs.view = new Date(rs.view.getFullYear(), rs.view.getMonth() + (k === 'prev' ? -1 : 1), 1);
  else if (b.dataset.day) { rs.date = new Date(rs.view.getFullYear(), rs.view.getMonth(), +b.dataset.day, rs.date.getHours(), rs.date.getMinutes()); rs.quick = null; }
  else if (b.dataset.wd) {
    const w = +b.dataset.wd, i = rs.weekdays.indexOf(w);
    if (i >= 0) rs.weekdays.splice(i, 1); else rs.weekdays.push(w);   // the last one can go too: Interval then reads Weekly, as on iOS
  }
  else if (k === 'current') { rs.place = { name: CURRENT_LOCATION, mode: 'arrive', radius: 150, notify: true, ...(rs.place || {}), name: rs.place?.name || CURRENT_LOCATION }; }
  else if (k === 'arrive' || k === 'leave') rs.place.mode = k;
  else return;
  paintReminder();
});
rsheet.addEventListener('change', e => {
  const k = e.target.dataset.r, v = e.target.type === 'checkbox' ? e.target.checked : e.target.value;
  if (!k) return;
  if (k === 'quick') { rs.quick = v; rs.date = quickDate(v); rs.time = hhmm(rs.date); rs.view = new Date(rs.date.getFullYear(), rs.date.getMonth(), 1); }
  else if (k === 'time') { rs.time = v || rs.time; rs.quick = null; }
  else if (k === 'allDay') rs.allDay = v;
  else if (k === 'notify') rs.notify = v;
  else if (k === 'repeat') { if (v) setInterval_('daily'); else { rs.repeat = 'none'; rs.weekdays = []; } }
  else if (k === 'interval') setInterval_(v);
  else if (k === 'radius') rs.place.radius = +v;
  else if (k === 'placeNotify') rs.place.notify = v;
  else if (k === 'name') { rs.place.name = storedPlaceName(v); return; }
  else return;
  paintReminder();
  rsheet.querySelector(`[data-r="${k}"]`)?.focus();
});
// Place search belongs to the shell (MapKit's address and point-of-interest suggestions). Here,
// Return takes what was typed as the place.
rsheet.addEventListener('keydown', e => {
  if (e.target.dataset?.r === 'query' && e.key === 'Enter' && e.target.value.trim()) {
    e.preventDefault();
    rs.query = '';
    rs.place = { mode: 'arrive', radius: 150, notify: true, ...(rs.place || {}), name: e.target.value.trim() };
    paintReminder();
  }
});
rsheet.addEventListener('input', e => { if (e.target.dataset?.r === 'name' && rs?.place) rs.place.name = storedPlaceName(e.target.value); if (e.target.dataset?.r === 'query' && rs) rs.query = e.target.value; });
// Escape closes the picker only, not the ring or the edit beneath it.
document.addEventListener('keydown', e => { if (reminderFor && e.key === 'Escape') { e.preventDefault(); e.stopImmediatePropagation(); cancelReminder(); } });
