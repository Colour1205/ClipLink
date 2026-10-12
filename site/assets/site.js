// ClipLink site: three small enhancements. The page works without any of them.
(function () {
  'use strict';

  var REPO = 'Colour1205/ClipLink';

  function safe(fn) {
    try { return fn(); } catch (e) { return null; }
  }

  // 1. A dismissible hint to switch language, for browsers set to Chinese.
  var hint = document.getElementById('lang-hint');
  if (hint) {
    var browserLang = (navigator.language || '').toLowerCase();
    var dismissed = safe(function () { return localStorage.getItem('lang-hint-dismissed'); });
    if (browserLang.indexOf(hint.getAttribute('data-for') || '-') === 0 && !dismissed) {
      hint.classList.add('show');
    }
    var close = hint.querySelector('button');
    if (close) {
      close.addEventListener('click', function () {
        hint.classList.remove('show');
        safe(function () { localStorage.setItem('lang-hint-dismissed', '1'); });
      });
    }
  }

  // 2. Mark the download card for the visitor's own platform.
  var ua = navigator.userAgent || '';
  var mine = /HarmonyOS|OpenHarmony/i.test(ua) ? 'harmonyos'
    : /Android/i.test(ua) ? 'android'
    : /iPhone|iPad|iPod/i.test(ua) ? 'ios'
    : /Windows/i.test(ua) ? 'windows' : '';
  if (mine) {
    var card = document.querySelector('[data-platform="' + mine + '"]');
    if (card) {
      card.classList.add('is-yours');
      var tag = card.querySelector('.badge-yours');
      if (tag) tag.hidden = false;
    }
  }

  // 3. Point the download buttons at the newest release's files. Without this
  // (or if GitHub can't be reached) they keep their fallback link to the
  // Releases page, and a platform with no file yet stays "coming soon".
  var buttons = document.querySelectorAll('[data-asset]');
  if (!buttons.length || !window.fetch) return;

  var patterns = { windows: /setup.*\.exe$/i, android: /\.apk$/i };

  function megabytes(bytes) {
    return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
  }

  fetch('https://api.github.com/repos/' + REPO + '/releases?per_page=10', {
    headers: { Accept: 'application/vnd.github+json' }
  })
    .then(function (response) {
      if (!response.ok) throw new Error('HTTP ' + response.status);
      return response.json();
    })
    .then(function (releases) {
      var published = releases.filter(function (release) { return !release.draft; });
      Array.prototype.forEach.call(buttons, function (button) {
        var pattern = patterns[button.getAttribute('data-asset')];
        if (!pattern) return;
        for (var i = 0; i < published.length; i++) {
          var asset = (published[i].assets || []).filter(function (a) { return pattern.test(a.name); })[0];
          if (!asset || String(asset.browser_download_url).indexOf('https://github.com/') !== 0) continue;
          button.href = asset.browser_download_url;
          button.removeAttribute('aria-disabled');
          button.textContent = button.getAttribute('data-label-ready') || button.textContent;
          var version = button.closest('.dl') && button.closest('.dl').querySelector('.js-version');
          if (version) version.textContent = published[i].tag_name + ' · ' + megabytes(asset.size);
          break;
        }
      });
    })
    .catch(function () { /* keep the fallback links */ });
})();
