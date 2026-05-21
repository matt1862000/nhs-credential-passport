/**
 * Hamburger menu + sign out for authenticated pages.
 */
(function (global) {
  function wire() {
    var btn = document.getElementById('btnMenu');
    var panel = document.getElementById('menuPanel');
    if (btn && panel) {
      function close() {
        panel.hidden = true;
        btn.setAttribute('aria-expanded', 'false');
      }
      function open() {
        panel.hidden = false;
        btn.setAttribute('aria-expanded', 'true');
      }
      btn.addEventListener('click', function (e) {
        e.preventDefault();
        if (panel.hidden) open();
        else close();
      });
      document.addEventListener(
        'click',
        function (e) {
          if (panel.hidden) return;
          if (btn.contains(e.target) || panel.contains(e.target)) return;
          close();
        },
        true
      );
      document.addEventListener('keydown', function (e) {
        if (e.key === 'Escape') close();
      });
    }

    var signOut = document.getElementById('btnSignOut');
    if (signOut && global.NHSAuth) {
      signOut.addEventListener('click', async function () {
        await NHSAuth.signOut();
        window.location.replace('/');
      });
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', wire);
  } else {
    wire();
  }

  global.NHSAppMenu = { wire: wire };
})(typeof window !== 'undefined' ? window : globalThis);
