/**
 * Header account strip: display name + messages link with unread badge.
 * Include after auth.js on signed-in pages. Replaces legacy #navEmail when present.
 */
(function (global) {
  var ENVELOPE_SVG =
    '<svg class="nhsuk-topnav__envelope" width="22" height="22" viewBox="0 0 24 24" aria-hidden="true" focusable="false">' +
    '<path fill="currentColor" d="M20 4H4c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V6c0-1.1-.9-2-2-2zm0 4l-8 5-8-5V6l8 5 8-5v2z"/>' +
    '</svg>';

  function accountMarkup() {
    return (
      '<div class="nhsuk-topnav__account" id="navAccount">' +
      '<span class="nhsuk-topnav__name" id="navUserName">&nbsp;</span>' +
      '<a href="/static/messages/" class="nhsuk-topnav__messages" id="navMessagesLink" aria-label="Messages">' +
      ENVELOPE_SVG +
      '<span class="nhsuk-topnav__msg-badge" id="navMsgBadge" hidden aria-live="polite"></span>' +
      '</a></div>'
    );
  }

  function upgradeLegacyNavEmail() {
    var old = document.getElementById('navEmail');
    if (!old || document.getElementById('navAccount')) return;
    var wrap = document.createElement('div');
    wrap.innerHTML = accountMarkup();
    var account = wrap.firstChild;
    old.parentNode.replaceChild(account, old);
  }

  async function refreshNavAccount() {
    if (!global.NHSAuth) return;
    await NHSAuth.refresh();
    if (!NHSAuth.user) return;

    upgradeLegacyNavEmail();

    var nameEl = document.getElementById('navUserName');
    var link = document.getElementById('navMessagesLink');
    var badge = document.getElementById('navMsgBadge');
    if (!nameEl) return;

    var label = typeof NHSAuth.displayName === 'function' ? NHSAuth.displayName() : '';
    nameEl.textContent = label || 'Account';
    if (NHSAuth.user.email) {
      nameEl.title = NHSAuth.user.email;
    }

    var isHr = !!NHSAuth.user.premium;
    var msgPath = isHr ? '/static/hr/messages/' : '/static/messages/';
    if (link) {
      link.href = msgPath;
      if (window.location.pathname.indexOf(msgPath.replace(/\/$/, '')) === 0) {
        link.setAttribute('aria-current', 'page');
      } else {
        link.removeAttribute('aria-current');
      }
    }

    var profileLink = document.querySelector('#menuPanel a[href*="/static/profile/"]');
    if (profileLink && NHSAuth.user.email) {
      profileLink.title = NHSAuth.user.email;
    }

    if (!badge || !link) return;
    var url = isHr ? '/api/hr/messages/unread-count' : '/api/me/messages/unread-count';
    try {
      var res = await fetch(url, { credentials: 'include' });
      if (!res.ok) {
        badge.hidden = true;
        link.setAttribute('aria-label', 'Messages');
        return;
      }
      var data = await res.json();
      var n = Number(data.unread || 0);
      if (n > 0) {
        badge.textContent = n > 99 ? '99+' : String(n);
        badge.hidden = false;
        link.setAttribute(
          'aria-label',
          'Messages, ' + n + ' unread message' + (n === 1 ? '' : 's')
        );
      } else {
        badge.textContent = '';
        badge.hidden = true;
        link.setAttribute('aria-label', 'Messages');
      }
    } catch (e) {
      badge.hidden = true;
      link.setAttribute('aria-label', 'Messages');
    }
  }

  function init() {
    upgradeLegacyNavEmail();
    void refreshNavAccount();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

  global.NHSNavAccount = { refresh: refreshNavAccount };
})(typeof window !== 'undefined' ? window : globalThis);
