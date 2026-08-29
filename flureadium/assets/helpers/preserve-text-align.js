/**
 * ReadiumCSS (ReadiumCSS-after.css) does this when --USER__textAlign is set:
 *
 *   :root[style*="readium-advanced-on"][style*="--USER__textAlign"]
 *     *:not(blockquote):not(figcaption) p {
 *       text-align: inherit !important;
 *     }
 *
 * That beats inline `style="text-align:center"` (inline without !important).
 * Flureadium therefore never forwards textAlign to Readium. Left/justify are
 * applied via --MBO__paraAlign / data-mbo-para-align with !important, but
 * only on <p> that are not publisher center/right. This script:
 *   1. Stamps publisher center/right on <p> as data-mbo-keep-align
 *   2. Applies the current user left/justify to html (and iframes)
 */
(function () {
  var KEEP = {
    center: 'center',
    right: 'right',
    end: 'right',
    '-webkit-center': 'center',
    '-moz-center': 'center',
  };

  var authorRules = [];

  function normalizeAlign(value) {
    return String(value || '')
      .trim()
      .toLowerCase()
      .replace(/["']/g, '');
  }

  function keepValue(value) {
    return KEEP[normalizeAlign(value)] || '';
  }

  function specificity(selector) {
    var ids = (selector.match(/#[\w-]+/g) || []).length;
    var classes = (selector.match(/\.[\w-]+|\[[^\]]+\]/g) || []).length;
    var elements = (selector.match(/(^|[\s>+~])[a-z][\w-]*/gi) || []).length;
    return ids * 10000 + classes * 100 + elements;
  }

  function sheetIsReadium(sheet) {
    var href = sheet.href || '';
    if (/readium|ReadiumCSS|flureadium/i.test(href)) return true;
    try {
      var rules = sheet.cssRules;
      if (!rules) return false;
      var limit = Math.min(rules.length, 30);
      for (var i = 0; i < limit; i++) {
        var text = rules[i].cssText || '';
        if (
          text.indexOf('--USER__') !== -1 ||
          text.indexOf('--RS__') !== -1 ||
          text.indexOf('--MBO__') !== -1
        ) {
          return true;
        }
      }
    } catch (err) {
      return true;
    }
    return false;
  }

  function collectRules(rules, out) {
    if (!rules) return;
    for (var i = 0; i < rules.length; i++) {
      var rule = rules[i];
      if (rule.type === 4 && rule.cssRules) {
        try {
          if (window.matchMedia && window.matchMedia(rule.conditionText).matches) {
            collectRules(rule.cssRules, out);
          }
        } catch (err) {}
        continue;
      }
      if (!rule.selectorText || !rule.style) continue;
      var align = normalizeAlign(rule.style.getPropertyValue('text-align'));
      if (!keepValue(align)) continue;
      out.push({
        selector: rule.selectorText,
        align: align,
        spec: specificity(rule.selectorText),
      });
    }
  }

  function refreshAuthorRules() {
    var collected = [];
    for (var i = 0; i < document.styleSheets.length; i++) {
      var sheet = document.styleSheets[i];
      if (sheetIsReadium(sheet)) continue;
      try {
        collectRules(sheet.cssRules, collected);
      } catch (err) {}
    }
    authorRules = collected;
  }

  function inlineAlign(el) {
    var style = el.getAttribute('style') || '';
    var match = style.match(/text-align\s*:\s*([a-z-]+)/i);
    if (match) return normalizeAlign(match[1]);
    return normalizeAlign(el.getAttribute('align'));
  }

  function stylesheetAlign(el) {
    var best = '';
    var bestSpec = -1;
    for (var i = 0; i < authorRules.length; i++) {
      var rule = authorRules[i];
      var parts = rule.selector.split(',');
      for (var j = 0; j < parts.length; j++) {
        var selector = parts[j].trim();
        if (!selector) continue;
        try {
          if (!el.matches(selector)) continue;
        } catch (err) {
          continue;
        }
        var spec = specificity(selector);
        if (spec >= bestSpec) {
          bestSpec = spec;
          best = rule.align;
        }
      }
    }
    return best;
  }

  function originalKeepAlign(el) {
    var inline = inlineAlign(el);
    var keep = keepValue(inline);
    if (keep) return keep;
    return keepValue(stylesheetAlign(el));
  }

  function stampP(el) {
    if (!el || el.tagName !== 'P') return;
    if (el.hasAttribute('data-mbo-keep-align')) return;
    var keep = originalKeepAlign(el);
    if (!keep) return;
    el.setAttribute('data-mbo-keep-align', keep);
  }

  function scan(root) {
    refreshAuthorRules();
    if (!root) return;
    if (root.nodeType === 1 && root.tagName === 'P') stampP(root);
    var scope = root.nodeType === 1 ? root : document;
    if (!scope.querySelectorAll) return;
    var nodes = scope.querySelectorAll('p');
    for (var i = 0; i < nodes.length; i++) stampP(nodes[i]);
  }

  function isUserOverride(value) {
    return value === 'left' || value === 'justify';
  }

  function currentAlign() {
    if (window.__MBO_PARA_ALIGN) return window.__MBO_PARA_ALIGN;
    try {
      return localStorage.getItem('mboParaAlign') || 'default';
    } catch (e) {
      return 'default';
    }
  }

  function applyUserAlign(align) {
    var value = normalizeAlign(align);
    if (!isUserOverride(value)) value = 'default';
    window.__MBO_PARA_ALIGN = value;
    try {
      localStorage.setItem('mboParaAlign', value);
    } catch (e) {}

    function applyDoc(doc) {
      if (!doc || !doc.documentElement) return;
      var override = isUserOverride(value);
      try {
        if (override) {
          doc.documentElement.style.setProperty('--MBO__paraAlign', value);
          doc.documentElement.setAttribute('data-mbo-para-align', value);
        } else {
          doc.documentElement.style.removeProperty('--MBO__paraAlign');
          doc.documentElement.removeAttribute('data-mbo-para-align');
        }
      } catch (e) {}
      try {
        var readium = doc.defaultView && doc.defaultView.readium;
        if (readium && readium.setCSSProperties) {
          readium.setCSSProperties({
            '--MBO__paraAlign': override ? value : null,
          });
        }
      } catch (e) {}
      try {
        var frames = doc.querySelectorAll('iframe');
        for (var i = 0; i < frames.length; i++) {
          try {
            applyDoc(frames[i].contentDocument);
          } catch (err) {}
        }
      } catch (e) {}
    }
    applyDoc(document);
  }

  window.__mboSetParaAlign = applyUserAlign;

  function run() {
    scan(document);
    applyUserAlign(currentAlign());
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', run);
  } else {
    run();
  }
  [50, 200, 500].forEach(function (ms) {
    setTimeout(run, ms);
  });
  window.addEventListener('pageshow', run);

  var observer = new MutationObserver(function (mutations) {
    for (var i = 0; i < mutations.length; i++) {
      var added = mutations[i].addedNodes;
      for (var j = 0; j < added.length; j++) {
        scan(added[j]);
      }
    }
  });

  function startObserver() {
    if (!document.documentElement) {
      setTimeout(startObserver, 0);
      return;
    }
    observer.observe(document.documentElement, {
      childList: true,
      subtree: true,
    });
  }
  startObserver();
})();
