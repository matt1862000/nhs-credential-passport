/**
 * Header account strip: display name + messages link with unread badge and hover preview.
 * Include after auth.js on signed-in pages. Replaces legacy #navEmail when present.
 */
(function (global) {
  var ENVELOPE_SVG =
    '<svg class="nhsuk-topnav__envelope" width="22" height="22" viewBox="0 0 24 24" aria-hidden="true" focusable="false">' +
    '<path fill="currentColor" d="M20 4H4c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V6c0-1.1-.9-2-2-2zm0 4l-8 5-8-5V6l8 5 8-5v2z"/>' +
    '</svg>';

  var PREVIEW_LIMIT = 5;
  var PREVIEW_CACHE_MS = 20000;
  var _previewCache = { at: 0, key: '', conversations: [] };
  var _previewHideTimer = null;
  var _previewShowTimer = null;
  var _previewWired = false;

  function esc(s) {
    var d = document.createElement('div');
    d.textContent = s == null ? '' : String(s);
    return d.innerHTML;
  }

  function accountMarkup() {
    return (
      '<div class="nhsuk-topnav__account" id="navAccount">' +
      '<span class="nhsuk-topnav__name" id="navUserName">&nbsp;</span>' +
      '<div class="nhsuk-topnav__messages-wrap" id="navMessagesWrap">' +
      '<a href="/static/messages/" class="nhsuk-topnav__messages" id="navMessagesLink" aria-label="Messages">' +
      ENVELOPE_SVG +
      '<span class="nhsuk-topnav__msg-badge" id="navMsgBadge" hidden aria-live="polite"></span>' +
      '</a>' +
      '<div class="nhsuk-topnav__msg-preview" id="navMessagesPreview" role="tooltip" hidden>' +
      '<p class="nhsuk-topnav__msg-preview-head">Messages</p>' +
      '<div class="nhsuk-topnav__msg-preview-body" id="navMessagesPreviewBody"></div>' +
      '<a class="nhsuk-topnav__msg-preview-foot" id="navMessagesPreviewAll" href="/static/messages/">View all messages</a>' +
      '</div></div></div>'
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

  function ensureMessagesPreviewUi() {
    var link = document.getElementById('navMessagesLink');
    if (!link || document.getElementById('navMessagesPreview')) return;

    if (link.parentNode && link.parentNode.id === 'navMessagesWrap') return;

    var wrap = document.createElement('div');
    wrap.className = 'nhsuk-topnav__messages-wrap';
    wrap.id = 'navMessagesWrap';
    link.parentNode.insertBefore(wrap, link);
    wrap.appendChild(link);

    var pop = document.createElement('div');
    pop.id = 'navMessagesPreview';
    pop.className = 'nhsuk-topnav__msg-preview';
    pop.hidden = true;
    pop.setAttribute('role', 'tooltip');
    pop.innerHTML =
      '<p class="nhsuk-topnav__msg-preview-head">Messages</p>' +
      '<div class="nhsuk-topnav__msg-preview-body" id="navMessagesPreviewBody"></div>' +
      '<a class="nhsuk-topnav__msg-preview-foot" id="navMessagesPreviewAll" href="/static/messages/">View all messages</a>';
    wrap.appendChild(pop);
  }

  function previewSnippet(body, max) {
    var t = String(body || '').replace(/\s+/g, ' ').trim();
    if (!t) return 'No messages yet';
    if (t.length <= (max || 72)) return t;
    return t.slice(0, max || 72) + '…';
  }

  function fmtPreviewTime(iso) {
    if (!iso) return '';
    try {
      var d = new Date(iso);
      if (isNaN(d.getTime())) return '';
      var now = new Date();
      var sameDay =
        d.getDate() === now.getDate() &&
        d.getMonth() === now.getMonth() &&
        d.getFullYear() === now.getFullYear();
      if (sameDay) {
        return d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' });
      }
      return d.toLocaleDateString(undefined, { day: 'numeric', month: 'short' });
    } catch (e) {
      return '';
    }
  }

  function conversationTitle(c, isHr) {
    if (isHr) {
      return (c.doctor_name && String(c.doctor_name).trim()) || c.doctor_email || 'Clinician';
    }
    return (c.hr_trust && String(c.hr_trust).trim()) || 'HR';
  }

  function renderPreviewBody(conversations, isHr, msgPath) {
    var body = document.getElementById('navMessagesPreviewBody');
    var foot = document.getElementById('navMessagesPreviewAll');
    if (foot) foot.href = msgPath;
    if (!body) return;

    if (!conversations.length) {
      body.innerHTML = '<p class="nhsuk-topnav__msg-preview-empty">No conversations yet.</p>';
      return;
    }

    var items = conversations.slice(0, PREVIEW_LIMIT);
    body.innerHTML = items
      .map(function (c) {
        var unread = Number(c.unread_count || 0);
        var href = msgPath + (msgPath.indexOf('?') >= 0 ? '&' : '?') + 'conv=' + encodeURIComponent(String(c.id));
        var badge =
          unread > 0
            ? '<span class="nhsuk-topnav__msg-preview-unread">' +
              esc(unread > 99 ? '99+' : String(unread)) +
              '</span>'
            : '';
        var time = fmtPreviewTime(c.last_message_at);
        var meta = time ? '<span class="nhsuk-topnav__msg-preview-time">' + esc(time) + '</span>' : '';
        return (
          '<a class="nhsuk-topnav__msg-preview-item' +
          (unread > 0 ? ' nhsuk-topnav__msg-preview-item--unread' : '') +
          '" href="' +
          esc(href) +
          '">' +
          '<span class="nhsuk-topnav__msg-preview-title">' +
          esc(conversationTitle(c, isHr)) +
          badge +
          '</span>' +
          '<span class="nhsuk-topnav__msg-preview-snippet">' +
          esc(previewSnippet(c.last_body)) +
          '</span>' +
          meta +
          '</a>'
        );
      })
      .join('');
  }

  async function fetchPreviewConversations(isHr) {
    var key = isHr ? 'hr' : 'me';
    var now = Date.now();
    if (_previewCache.key === key && now - _previewCache.at < PREVIEW_CACHE_MS) {
      return _previewCache.conversations;
    }
    var url = isHr ? '/api/hr/messages' : '/api/me/messages';
    var res = await fetch(url, { credentials: 'include' });
    if (!res.ok) throw new Error('Could not load messages');
    var data = await res.json();
    var convs = data.conversations || [];
    _previewCache = { at: now, key: key, conversations: convs };
    return convs;
  }

  function hideMessagesPreview() {
    var pop = document.getElementById('navMessagesPreview');
    var link = document.getElementById('navMessagesLink');
    if (pop) pop.hidden = true;
    if (link) link.removeAttribute('aria-describedby');
  }

  function showMessagesPreview() {
    var pop = document.getElementById('navMessagesPreview');
    var link = document.getElementById('navMessagesLink');
    if (!pop) return;
    pop.hidden = false;
    if (link) link.setAttribute('aria-describedby', 'navMessagesPreview');
  }

  async function openMessagesPreview() {
    if (!global.NHSAuth || !NHSAuth.user) return;
    var body = document.getElementById('navMessagesPreviewBody');
    if (body) {
      body.innerHTML = '<p class="nhsuk-topnav__msg-preview-loading">Loading…</p>';
    }
    showMessagesPreview();
    var isHr = !!NHSAuth.user.premium;
    var msgPath = isHr ? '/static/hr/messages/' : '/static/messages/';
    try {
      var convs = await fetchPreviewConversations(isHr);
      renderPreviewBody(convs, isHr, msgPath);
    } catch (e) {
      if (body) {
        body.innerHTML = '<p class="nhsuk-topnav__msg-preview-empty">Could not load preview.</p>';
      }
    }
  }

  function scheduleShowPreview() {
    if (_previewHideTimer) {
      clearTimeout(_previewHideTimer);
      _previewHideTimer = null;
    }
    if (_previewShowTimer) clearTimeout(_previewShowTimer);
    _previewShowTimer = setTimeout(function () {
      _previewShowTimer = null;
      void openMessagesPreview();
    }, 280);
  }

  function scheduleHidePreview() {
    if (_previewShowTimer) {
      clearTimeout(_previewShowTimer);
      _previewShowTimer = null;
    }
    if (_previewHideTimer) clearTimeout(_previewHideTimer);
    _previewHideTimer = setTimeout(function () {
      _previewHideTimer = null;
      hideMessagesPreview();
    }, 220);
  }

  function wireMessagesPreview() {
    if (_previewWired) return;
    var wrap = document.getElementById('navMessagesWrap');
    if (!wrap) return;
    _previewWired = true;

    wrap.addEventListener('mouseenter', scheduleShowPreview);
    wrap.addEventListener('mouseleave', scheduleHidePreview);
    wrap.addEventListener('focusin', scheduleShowPreview);
    wrap.addEventListener('focusout', function (e) {
      if (wrap.contains(e.relatedTarget)) return;
      scheduleHidePreview();
    });

    var pop = document.getElementById('navMessagesPreview');
    if (pop) {
      pop.addEventListener('mouseenter', function () {
        if (_previewHideTimer) {
          clearTimeout(_previewHideTimer);
          _previewHideTimer = null;
        }
      });
      pop.addEventListener('mouseleave', scheduleHidePreview);
    }
  }

  async function refreshNavAccount() {
    if (!global.NHSAuth) return;
    await NHSAuth.refresh();
    if (!NHSAuth.user) return;

    upgradeLegacyNavEmail();
    ensureMessagesPreviewUi();
    wireMessagesPreview();

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
    var foot = document.getElementById('navMessagesPreviewAll');
    if (foot) foot.href = msgPath;

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
      _previewCache.at = 0;
    } catch (e) {
      badge.hidden = true;
      link.setAttribute('aria-label', 'Messages');
    }
  }

  function init() {
    upgradeLegacyNavEmail();
    ensureMessagesPreviewUi();
    wireMessagesPreview();
    void refreshNavAccount();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

  global.NHSNavAccount = { refresh: refreshNavAccount };
})(typeof window !== 'undefined' ? window : globalThis);
