// ClipLink site: small enhancements. The page works without any of them.
// (The language choice is made by a tiny inline script in each page's <head>,
// so the right language shows without a flash.)
(function () {
  'use strict';

  var REPO = 'Colour1205/ClipLink';

  // ---- 1. Mark the download card for the visitor's own platform. ----
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

  // ---- 2. On small phones, "See it in action" is a swipeable, looping stack. ----
  // The frames sit on top of each other: the one in front can be dragged left
  // or right to go to the next (or back) and the stack goes round in a circle -
  // after the last comes the first. The ones behind are blurred, and vertical
  // swipes still scroll the page (touch-action: pan-y). The phones come first
  // and the wide Windows window last, so a small one is never the first thing
  // you see. Wider screens, and browsers without JavaScript, keep the grid.
  var box = document.querySelector('.showcase');
  if (box && window.matchMedia) {
    initStack(box);
  }

  function initStack(root) {
    var all = Array.prototype.slice.call(root.querySelectorAll('.frame'));
    if (all.length < 2) return;
    var phones = all.filter(function (frame) { return !frame.classList.contains('frame-win'); });
    var wide = all.filter(function (frame) { return frame.classList.contains('frame-win'); });
    var frames = phones.concat(wide);
    var count = frames.length;
    var query = window.matchMedia('(max-width: 620px)');
    var active = 0;
    var leaving = -1; // the frame that has just flown off to the left
    var leaveTimer = 0;
    var dots = null;
    var hint = null;
    var drag = null; // { x, y, id, horizontal, dx }

    function build() {
      root.classList.add('is-stack');
      root.setAttribute('role', 'region');
      root.setAttribute('aria-roledescription', 'carousel');
      root.setAttribute('tabindex', '0');
      dots = document.createElement('div');
      dots.className = 'stack-dots';
      frames.forEach(function (frame, i) {
        var caption = frame.querySelector('figcaption');
        var dot = document.createElement('button');
        dot.type = 'button';
        dot.className = 'stack-dot';
        dot.setAttribute('aria-label', caption ? caption.textContent : String(i + 1));
        dot.addEventListener('click', function () { jump(i); });
        dots.appendChild(dot);
      });
      root.parentNode.insertBefore(dots, root.nextSibling);
      var text = root.getAttribute('data-hint');
      if (text) {
        hint = document.createElement('p');
        hint.className = 'stack-hint';
        hint.textContent = text;
        dots.parentNode.insertBefore(hint, dots.nextSibling);
      }
      active = 0;
      leaving = -1;
      render();
    }

    function destroy() {
      clearTimeout(leaveTimer);
      root.classList.remove('is-stack', 'dragging');
      root.removeAttribute('role');
      root.removeAttribute('aria-roledescription');
      root.removeAttribute('tabindex');
      all.forEach(function (frame) {
        frame.removeAttribute('data-pos');
        frame.removeAttribute('aria-hidden');
        frame.inert = false;
        frame.style.removeProperty('--dx');
        frame.style.removeProperty('--rot');
      });
      if (dots) { dots.remove(); dots = null; }
      if (hint) { hint.remove(); hint = null; }
    }

    // Where each frame is: 0 in front, 1 and 2 peeking out behind it, 3 hidden
    // further back, -1 flown off to the left. It is a circle, so the one just in
    // front of the active frame is the last one back.
    function render() {
      frames.forEach(function (frame, i) {
        var pos = ((i - active) % count + count) % count;
        if (pos > 3) pos = 3;
        if (i === leaving) pos = -1;
        frame.setAttribute('data-pos', String(pos));
        frame.setAttribute('aria-hidden', pos === 0 ? 'false' : 'true');
        frame.inert = pos !== 0;
        if (pos === 0) {
          frame.style.removeProperty('--dx');
          frame.style.removeProperty('--rot');
        }
      });
      if (dots) {
        Array.prototype.forEach.call(dots.children, function (dot, i) {
          if (i === active) dot.setAttribute('aria-current', 'true');
          else dot.removeAttribute('aria-current');
        });
      }
    }

    function next() {
      var old = active;
      active = (active + 1) % count;
      leaving = old; // it flies off to the left, then waits at the back
      clearTimeout(leaveTimer);
      leaveTimer = setTimeout(function () { leaving = -1; render(); }, 450);
      render();
    }

    function previous() {
      // The frame at the back comes round from the left.
      var incoming = (active - 1 + count) % count;
      var frame = frames[incoming];
      leaving = -1;
      frame.style.transition = 'none';
      frame.setAttribute('data-pos', '-1');
      void frame.offsetWidth; // let it sit there before it moves
      frame.style.transition = '';
      active = incoming;
      render();
    }

    function jump(index) {
      if (index === active) return;
      leaving = -1;
      active = index;
      render();
    }

    function setDrag(dx) {
      var front = frames[active];
      front.style.setProperty('--dx', dx + 'px');
      front.style.setProperty('--rot', (dx / 28).toFixed(2) + 'deg');
    }

    root.addEventListener('pointerdown', function (event) {
      if (!root.classList.contains('is-stack') || (event.pointerType === 'mouse' && event.button !== 0)) return;
      drag = { x: event.clientX, y: event.clientY, id: event.pointerId, horizontal: false, dx: 0 };
    });

    root.addEventListener('pointermove', function (event) {
      if (!drag || event.pointerId !== drag.id) return;
      var dx = event.clientX - drag.x;
      var dy = event.clientY - drag.y;
      if (!drag.horizontal) {
        if (Math.abs(dy) > 10 && Math.abs(dy) > Math.abs(dx)) { drag = null; return; } // a scroll: not ours
        if (Math.abs(dx) < 8) return;
        drag.horizontal = true;
        root.classList.add('dragging');
        try { root.setPointerCapture(event.pointerId); } catch (e) { /* not capturable: fine */ }
      }
      drag.dx = dx;
      setDrag(dx);
    });

    function release(event) {
      if (!drag || event.pointerId !== drag.id) return;
      var finished = drag;
      drag = null;
      root.classList.remove('dragging');
      if (!finished.horizontal) return;
      var threshold = Math.min(90, root.clientWidth * 0.2);
      if (finished.dx < -threshold) next();
      else if (finished.dx > threshold) previous();
      else render(); // snap back
    }
    root.addEventListener('pointerup', release);
    root.addEventListener('pointercancel', release);

    root.addEventListener('keydown', function (event) {
      if (!root.classList.contains('is-stack')) return;
      if (event.key === 'ArrowRight') { next(); event.preventDefault(); }
      else if (event.key === 'ArrowLeft') { previous(); event.preventDefault(); }
    });

    function sync() {
      if (query.matches) {
        if (!root.classList.contains('is-stack')) build();
      } else if (root.classList.contains('is-stack')) {
        destroy();
      }
    }
    if (query.addEventListener) query.addEventListener('change', sync);
    else if (query.addListener) query.addListener(sync);
    sync();
  }

  // ---- 3. Point the download buttons at the newest release's files. ----
  // Without this (or if GitHub can't be reached) they keep their fallback link
  // to the Releases page, and a platform with no file yet stays "coming soon".
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
