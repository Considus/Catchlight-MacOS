'use strict';
// Links in a Take's text (LinkDetector.swift, owner 2026-06-22). Loaded after tlds.js and before
// takes.js. Two passes, as on iOS:
//   1. Schemed links, www. links and email addresses: what NSDataDetector finds. A link typed
//      without a scheme opens as https://; an email opens mail.
//   2. Bare domains with no scheme ("catchlight.app"), linked only when the ending is a real
//      top-level domain (TLDS). Two gates keep a personal note from sprouting false links:
//      the four endings that are mostly file extensions are not in the list, and the ending
//      must be lower case ("home.It" is a missing space, not Italy), unless the whole match
//      is in capitals ("SQUOOSH.APP").
// The real app gets this from CatchlightCore; this is the prototype's copy of the same rules.

const SCHEMED = /\b(?:https?|ftp):\/\/[^\s<>"]+|\bwww\.[^\s<>"]+|\b[\w.+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+/gi;
const BARE_DOMAIN = /(?<![@./\w-])((?:[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+([a-zA-Z]{2,24}))(\/[^\s]*)?/g;

// A detector stops before the punctuation that ends a sentence, and before a closing bracket
// it didn't open.
function trimLinkEnd(s) {
  for (;;) {
    if (/[.,;:!?'"]$/.test(s)) { s = s.slice(0, -1); continue; }
    if (s.endsWith(')') && (s.match(/\(/g) || []).length < (s.match(/\)/g) || []).length) { s = s.slice(0, -1); continue; }
    return s;
  }
}

// Every link in `text`, by position and never overlapping: [{ start, end, url }].
function detectLinks(text) {
  if (!text) return [];
  const found = [];
  for (const m of text.matchAll(SCHEMED)) {
    const raw = trimLinkEnd(m[0]);
    if (!raw) continue;
    const url = raw.includes('@') && !raw.includes('://') ? 'mailto:' + raw : raw.includes('://') ? raw : 'https://' + raw;
    found.push({ start: m.index, end: m.index + raw.length, url });
  }
  for (const m of text.matchAll(BARE_DOMAIN)) {
    const start = m.index, end = start + m[0].length;
    if (found.some(f => start < f.end && f.start < end)) continue;   // a pass-1 link already covers it
    const tld = m[2];
    if (tld !== tld.toLowerCase() && m[0] !== m[0].toUpperCase()) continue;
    if (!TLDS.has(tld.toLowerCase())) continue;
    found.push({ start, end, url: 'https://' + m[0] });
  }
  return found.sort((a, b) => a.start - b.start);
}

// `text` as HTML with its links live: accent, underlined, opening outside the app.
function linkify(text) {
  let html = '', at = 0;
  for (const l of detectLinks(text)) {
    html += esc(text.slice(at, l.start))
      + `<a class="tlink" href="${esc(l.url)}" target="_blank" rel="noopener">${esc(text.slice(l.start, l.end))}</a>`;
    at = l.end;
  }
  return html + esc(text.slice(at));
}
