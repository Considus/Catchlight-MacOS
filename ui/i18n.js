'use strict';
// Localisation for the page. Loaded first: every other file calls t() as it paints.
//
// The strings live in l10n/Localizable.xcstrings, Xcode's String Catalog format, so the page and
// the native apps share one way of holding a translation and the same checks run on both. It is
// read as it is, with no build step. The key is the English sentence; a missing key or language
// falls back to English.
//
//   t('Delete this Take?')                          a plain string
//   t('Created on %@ at %@', date, time)            placeholders, in order (%@, %lld, %d)
//   t('%1$@ at %2$@', a, b)                         or by position, which a translation may reorder
//   t('%lld Takes changed on another device.', n)   a plural: the catalog holds each form
//
// A plural form is chosen by Intl.PluralRules for the first number among the arguments. A key
// whose value uses %#@name@ takes each named part from the entry's `substitutions`, as Xcode
// does, so one sentence can carry two counts. Static text in index.html carries `data-i18n` (its
// text is the key) or `data-i18n-attrs="title aria-label"` (each listed attribute's value is).
//
// The language is the shell's (`catchlightShell.language`, which its native menus and alerts use
// too), else the browser's, else English. `?lang=de` overrides both, to look at a translation in
// a browser.
(() => {
  const SUPPORTED = ['en', 'es', 'fr', 'de', 'zh-Hans', 'zh-Hant', 'da', 'nl', 'fi', 'it', 'ja', 'nb', 'pl', 'pt-BR', 'pt-PT', 'sv', 'th', 'tr', 'ko'];

  // One preferred language (a BCP 47 tag) to the catalog language it reads in, or null.
  function match(tag) {
    if (!tag) return null;
    const exact = SUPPORTED.find(l => l.toLowerCase() === String(tag).toLowerCase());
    if (exact) return exact;
    let loc;
    try { loc = new Intl.Locale(tag).maximize(); } catch { return null; }
    const { language, script, region } = loc;
    if (language === 'zh') return script === 'Hant' ? 'zh-Hant' : 'zh-Hans';
    if (language === 'pt') return region === 'BR' ? 'pt-BR' : 'pt-PT';
    if (language === 'no' || language === 'nn' || language === 'nb') return 'nb';
    return SUPPORTED.includes(language) ? language : null;
  }
  const fromQuery = (() => { try { return new URLSearchParams(location.search).get('lang'); } catch { return null; } })();
  const preferred = navigator.languages?.length ? navigator.languages : [navigator.language];
  // A shell always names one (ShellBridge.preferredLanguage), and its choice stands: the native
  // menus and alerts use the same one. Only a plain browser reads its own preferences.
  const shellLanguage = window.catchlightShell?.language;
  const lang = match(fromQuery) || (shellLanguage ? match(shellLanguage) || 'en' : preferred.map(match).find(Boolean) || 'en');
  // For dates and numbers: the user's own tag in that language (de-CH, say), else the language.
  const regional = preferred.find(l => match(l) === lang) || lang;

  // The catalog, read synchronously so the first paint is already in the right language. In a
  // shell it comes from the app's own folder (catchlight://app/), never the network.
  // English reads it too, for the singular forms of its plurals.
  let strings = {};
  try {
    const xhr = new XMLHttpRequest();
    xhr.open('GET', 'l10n/Localizable.xcstrings', false);
    xhr.overrideMimeType('application/json');
    xhr.send();
    if (xhr.status === 200 || (xhr.status === 0 && xhr.responseText)) strings = JSON.parse(xhr.responseText).strings || {};
  } catch (e) { console.error('The translations did not load; the page stays in English', e); }

  const rules = {};
  const pluralRule = l => rules[l] ??= (() => { try { return new Intl.PluralRules(l); } catch { return new Intl.PluralRules('en'); } })();
  const form = (variations, l, n) => {
    const plural = variations?.plural;
    if (!plural) return null;
    const unit = plural[pluralRule(l).select(n)] || plural.other;
    return unit?.stringUnit?.value ?? null;
  };
  const firstNumber = args => args.find(a => typeof a === 'number');

  // The text for `key` in `l`, before its placeholders are filled; null when it has none.
  function lookup(key, l, args) {
    const loc = strings[key]?.localizations?.[l];
    if (!loc) return null;
    let value = loc.stringUnit?.value ?? form(loc.variations, l, firstNumber(args) ?? 0);
    if (value == null) return null;
    if (loc.substitutions) {
      value = value.replace(/%(?:\d+\$)?#@(\w+)@/g, (whole, name) => {
        const sub = loc.substitutions[name];
        if (!sub) return whole;
        const n = args[(sub.argNum || 1) - 1];
        const text = form(sub.variations, l, typeof n === 'number' ? n : 0);
        return text == null ? whole : text.replace(/%(?:\d+\$)?(?:arg|lld|ld|d|@)/g, () => format(n));
      });
    }
    return value;
  }
  const format = v => typeof v === 'number' ? v.toLocaleString(regional) : String(v ?? '');
  function fill(text, args) {
    let next = 0;
    return text.replace(/%(?:(\d+)\$)?(@|lld|ld|d|%)/g, (whole, pos, spec) => {
      if (spec === '%') return '%';
      const i = pos ? +pos - 1 : next++;
      return i < args.length ? format(args[i]) : whole;
    });
  }

  // English is the key itself, unless the catalog gives English its own text: a plural's forms,
  // two counts' substitutions, or a key whose English differs ("View menu" reads "View"). Those
  // are also here, so a page whose catalog didn't load still reads right ("1 Take changed…").
  // LocalisationTests checks this table against the catalog's English.
  const ENGLISH = {
    "%1$@ at %2$@": "%1$@ at %2$@",
    "%1$@ · %2$lld pages": {"one": "%1$@ · %2$lld page", "other": "%1$@ · %2$lld pages"},
    "%1$@. %2$@": "%1$@. %2$@",
    "%1$lld Takes and %2$lld Scripts changed on another device.": {"value": "%#@takes@ and %#@scripts@ changed on another device.", "substitutions": {"scripts": [2, "%arg Script", "%arg Scripts"], "takes": [1, "%arg Take", "%arg Takes"]}},
    "%1$lld of %2$lld completed": "%1$lld of %2$lld completed",
    "%lld Scripts changed on another device.": {"one": "%lld Script changed on another device.", "other": "%lld Scripts changed on another device."},
    "%lld Scripts couldn't be opened": {"one": "%lld Script couldn't be opened", "other": "%lld Scripts couldn't be opened"},
    "%lld Scripts weren't changed": {"one": "%lld Script wasn't changed", "other": "%lld Scripts weren't changed"},
    "%lld Takes and Scripts changed on another device.": {"one": "%lld Take or Script changed on another device.", "other": "%lld Takes and Scripts changed on another device."},
    "%lld Takes changed on another device.": {"one": "%lld Take changed on another device.", "other": "%lld Takes changed on another device."},
    "%lld Takes couldn't be verified and need a choice.": {"one": "%lld Take couldn't be verified and needs a choice.", "other": "%lld Takes couldn't be verified and need a choice."},
    "%lld Takes couldn't be verified and were skipped.": {"one": "%lld Take couldn't be verified and was skipped.", "other": "%lld Takes couldn't be verified and were skipped."},
    "%lld Takes not re-uploaded. This device was away too long to rule out deletion elsewhere. Edit a Take to sync it again.": {"one": "%lld Take not re-uploaded. This device was away too long to rule out deletion elsewhere. Edit a Take to sync it again.", "other": "%lld Takes not re-uploaded. This device was away too long to rule out deletion elsewhere. Edit a Take to sync it again."},
    "%lld Takes weren't changed": {"one": "%lld Take wasn't changed", "other": "%lld Takes weren't changed"},
    "%lld notes couldn't be saved. Import again to try them, and if it keeps happening, report it.": {"one": "%lld note couldn't be saved. Import again to try it, and if it keeps happening, report it.", "other": "%lld notes couldn't be saved. Import again to try them, and if it keeps happening, report it."},
    "Catchlight couldn't read %lld Scripts, so the last version of each is kept. Report it, with this detail: %@": {"one": "Catchlight couldn't read %lld Script, so the last version of it is kept. Report it, with this detail: %@", "other": "Catchlight couldn't read %lld Scripts, so the last version of each is kept. Report it, with this detail: %@"},
    "Catchlight couldn't read %lld Takes, so the last version of each is kept. Report it, with this detail: %@": {"one": "Catchlight couldn't read %lld Take, so the last version of it is kept. Report it, with this detail: %@", "other": "Catchlight couldn't read %lld Takes, so the last version of each is kept. Report it, with this detail: %@"},
    "Created on %1$@ at %2$@": "Created on %1$@ at %2$@",
    "Email to %1$@ and %2$lld more emails": {"one": "Email to %@ and %lld more email", "other": "Email to %@ and %lld more emails"},
    "Import successful. %1$lld Takes and %2$lld Scripts added to your timeline.": {"value": "Import successful. %#@takes@ and %#@scripts@ added to your timeline.", "substitutions": {"scripts": [2, "%arg Script", "%arg Scripts"], "takes": [1, "%arg Take", "%arg Takes"]}},
    "Import successful. %lld Scripts added to your timeline.": {"one": "Import successful. %lld Script added to your timeline.", "other": "Import successful. %lld Scripts added to your timeline."},
    "Import successful. %lld Takes added to your timeline.": {"one": "Import successful. %lld Take added to your timeline.", "other": "Import successful. %lld Takes added to your timeline."},
    "Link to %1$@ and %2$lld more links": {"one": "Link to %@ and %lld more link", "other": "Link to %@ and %lld more links"},
    "Task, %1$lld of %2$lld complete": "Task, %1$lld of %2$lld complete",
    "View menu": "View",
  };
  function english(key, args) {
    const e = ENGLISH[key];
    if (e == null) return null;
    if (typeof e === 'string') return e;
    const n = firstNumber(args) ?? 0;
    if (!e.substitutions) return n === 1 ? e.one : e.other;
    return e.value.replace(/%(?:\d+\$)?#@(\w+)@/g, (whole, name) => {
      const [argNum, one, other] = e.substitutions[name] || [];
      if (!argNum) return whole;
      const v = args[argNum - 1];
      return (v === 1 ? one : other).replace(/%arg/g, () => format(v));
    });
  }
  function t(key, ...args) {
    const text = lookup(key, lang, args) ?? lookup(key, 'en', args) ?? english(key, args) ?? key;
    return fill(text, args);
  }
  // English from the built-in table alone, as a page without its catalog would read.
  t.fallback = (key, ...args) => fill(english(key, args) ?? key, args);

  // Static text in index.html (and any fragment painted later that carries the attributes).
  function apply(root = document) {
    for (const el of root.querySelectorAll('[data-i18n]')) {
      el.dataset.i18nKey ??= el.textContent.trim();
      el.textContent = t(el.dataset.i18nKey);
    }
    for (const el of root.querySelectorAll('[data-i18n-attrs]')) {
      for (const attr of el.dataset.i18nAttrs.split(/\s+/).filter(Boolean)) {
        const keyAttr = 'data-i18n-' + attr;
        if (!el.hasAttribute(keyAttr)) el.setAttribute(keyAttr, el.getAttribute(attr) ?? '');
        el.setAttribute(attr, t(el.getAttribute(keyAttr)));
      }
    }
  }

  document.documentElement.lang = lang === 'en' ? document.documentElement.lang || 'en' : lang;
  // A locale for Intl: English keeps whatever each caller already used (`fallback`).
  const dateLocale = fallback => (lang === 'en' ? fallback : regional);
  // Words joined as a list ("Obie, Important, Task"), in the language's own separators.
  const list = parts => {
    if (lang === 'en' || !Intl.ListFormat) return parts.join(', ');
    try { return new Intl.ListFormat(regional, { type: 'unit', style: 'short' }).format(parts); } catch { return parts.join(', '); }
  };
  // Whole sentences one after another: a space between them, none in Chinese or Japanese.
  const sentences = (...parts) => parts.filter(Boolean).join(/^(ja|zh)/.test(lang) ? '' : ' ');
  // Phrases a screen reader reads as one label ("Buy film. Task, 1 of 2 complete. Overdue"), with
  // the pause the language marks: a full stop and space, 。 in Chinese and Japanese, a space in Thai.
  const clauses = parts => parts.filter(Boolean).join(/^(ja|zh)/.test(lang) ? '。' : lang === 'th' ? ' ' : '. ');
  window.L10N = Object.freeze({ lang, locale: regional, supported: SUPPORTED, match, t, apply, dateLocale, list, sentences, clauses });
  window.t = t;
  apply();
})();
