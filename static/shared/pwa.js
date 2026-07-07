/**
 * DocPass PWA — service worker registration and install prompt.
 */
(function (global) {
  var SW_URL = '/static/sw.js';
  var SW_SCOPE = '/static/';
  var DISMISS_KEY = 'docpass_pwa_install_dismissed';
  var DISMISS_DAYS = 14;

  function isStandalone() {
    return global.matchMedia('(display-mode: standalone)').matches ||
      global.navigator.standalone === true;
  }

  function wasDismissedRecently() {
    try {
      var raw = localStorage.getItem(DISMISS_KEY);
      if (!raw) return false;
      var ts = parseInt(raw, 10);
      return !isNaN(ts) && (Date.now() - ts) < DISMISS_DAYS * 86400000;
    } catch (e) {
      return false;
    }
  }

  function dismissBanner() {
    try { localStorage.setItem(DISMISS_KEY, String(Date.now())); } catch (e) { /* ignore */ }
    var el = document.getElementById('docpass-pwa-install');
    if (el) el.remove();
  }

  function registerServiceWorker() {
    if (!('serviceWorker' in navigator)) return;
    navigator.serviceWorker.register(SW_URL, { scope: SW_SCOPE }).catch(function () {
      /* non-fatal */
    });
  }

  function showInstallBanner(deferredPrompt) {
    if (isStandalone() || wasDismissedRecently()) return;
    if (document.getElementById('docpass-pwa-install')) return;

    var bar = document.createElement('div');
    bar.id = 'docpass-pwa-install';
    bar.className = 'docpass-pwa-install';
    bar.setAttribute('role', 'region');
    bar.setAttribute('aria-label', 'Install DocPass');
    bar.innerHTML =
      '<div class="docpass-pwa-install__inner">' +
        '<p class="docpass-pwa-install__text">' +
          '<strong>Add DocPass to your home screen</strong> for quick access to your training wallet and alerts.' +
        '</p>' +
        '<div class="docpass-pwa-install__actions">' +
          '<button type="button" class="docpass-pwa-install__btn docpass-pwa-install__btn--primary" id="docpass-pwa-install-go">Install</button>' +
          '<button type="button" class="docpass-pwa-install__btn docpass-pwa-install__btn--ghost" id="docpass-pwa-install-dismiss">Not now</button>' +
        '</div>' +
      '</div>';

    document.body.appendChild(bar);

    document.getElementById('docpass-pwa-install-dismiss').addEventListener('click', dismissBanner);
    document.getElementById('docpass-pwa-install-go').addEventListener('click', function () {
      deferredPrompt.prompt();
      deferredPrompt.userChoice.finally(function () {
        dismissBanner();
      });
    });
  }

  function showIosHint() {
    if (isStandalone() || wasDismissedRecently()) return;
    var ua = navigator.userAgent || '';
    var isIos = /iPad|iPhone|iPod/.test(ua) && !global.MSStream;
    if (!isIos) return;
    if (document.getElementById('docpass-pwa-install')) return;

    var bar = document.createElement('div');
    bar.id = 'docpass-pwa-install';
    bar.className = 'docpass-pwa-install docpass-pwa-install--ios';
    bar.setAttribute('role', 'region');
    bar.setAttribute('aria-label', 'Add DocPass to home screen');
    bar.innerHTML =
      '<div class="docpass-pwa-install__inner">' +
        '<p class="docpass-pwa-install__text">' +
          'Tap <strong>Share</strong>, then <strong>Add to Home Screen</strong> to open DocPass like an app.' +
        '</p>' +
        '<button type="button" class="docpass-pwa-install__btn docpass-pwa-install__btn--ghost" id="docpass-pwa-install-dismiss">Got it</button>' +
      '</div>';
    document.body.appendChild(bar);
    document.getElementById('docpass-pwa-install-dismiss').addEventListener('click', dismissBanner);
  }

  global.addEventListener('beforeinstallprompt', function (e) {
    e.preventDefault();
    showInstallBanner(e);
  });

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () {
      registerServiceWorker();
      showIosHint();
    });
  } else {
    registerServiceWorker();
    showIosHint();
  }
})(window);
