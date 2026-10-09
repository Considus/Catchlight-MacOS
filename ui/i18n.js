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

  // English is the key itself, unless the catalog gives English its own forms (a plural's).
  function t(key, ...args) {
    const text = lookup(key, lang, args) ?? lookup(key, 'en', args) ?? key;
    return fill(text, args);
  }

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
  window.L10N = Object.freeze({ lang, locale: regional, supported: SUPPORTED, match, t, apply, dateLocale, list, sentences });
  window.t = t;
  apply();
})();
