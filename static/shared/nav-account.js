/**
 * Header account strip: display name + messages link with unread badge, hover preview,
 * and background polling for new messages.
 */
(function (global) {
  var ENVELOPE_SVG =
    '<svg class="nhsuk-topnav__envelope" width="22" height="22" viewBox="0 0 24 24" aria-hidden="true" focusable="false">' +
    '<path fill="currentColor" d="M20 4H4c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V6c0-1.1-.9-2-2-2zm0 4l-8 5-8-5V6l8 5 8-5v2z"/></svg>';

  var ENVELOPE_SVG_UNREAD =
    '<svg class="nhsuk-topnav__envelope" width="22" height="22" viewBox="0 0 24 24" aria-hidden="true" focusable="false">' +
    '<path fill="currentColor" d="M20 4H4c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V6c0-1.1-.9-2-2-2zm-1.2 4.2l-6.8 4.25L5.2 8.2V6l6.8 4.25L18.8 6v2.2z"/>' +
    '<circle class="nhsuk-topnav__envelope-dot" cx="18.5" cy="7" r="3.25" fill="#d5281b" stroke="#fff" stroke-width="1.25"/></svg>';

  var PREVIEW_LIMIT = 5;
  var PREVIEW_CACHE_MS = 20000;
  var UNREAD_POLL_MS = 15000;
  var _previewCache = { at: 0, key: '', conversations: [] };
  var _previewHideTimer = null;
  var _previewShowTimer = null;
  var _previewWired = false;
  var _unreadPollTimer = null;
  var _unreadPollWired = false;
  var _lastUnreadCount = 0;
  var _newMsgFlashTimer = null;

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

  function setEnvelopeGraphic(link, hasUnread) {
    if (!link) return;
    var badge = link.querySelector('#navMsgBadge') || link.querySelector('.nhsuk-topnav__msg-badge');
    var badgeHtml = badge ? badge.outerHTML : '';
    link.innerHTML = (hasUnread ? ENVELOPE_SVG_UNREAD : ENVELOPE_SVG) + badgeHtml;
  }

  function applyUnreadVisual(link, count) {
    if (!link) return;
    var n = Number(count || 0);
    var hadUnread = link.classList.contains('nhsuk-topnav__messages--unread');
    if ((n > 0) !== hadUnread) {
      setEnvelopeGraphic(link, n > 0);
    }
    var badge = link.querySelector('.nhsuk-topnav__msg-badge');
    if (n > 0) {
      link.classList.add('nhsuk-topnav__messages--unread');
      if (n > _lastUnreadCount || (!hadUnread && n > 0)) {
        link.classList.add('nhsuk-topnav__messages--new');
        if (_newMsgFlashTimer) clearTimeout(_newMsgFlashTimer);
        _newMsgFlashTimer = setTimeout(function () {
          link.classList.remove('nhsuk-topnav__messages--new');
          _newMsgFlashTimer = null;
        }, 2800);
      }
      if (badge) {
        badge.textContent = n > 99 ? '99+' : String(n);
        badge.hidden = false;
      }
      link.setAttribute('aria-label', 'Messages, ' + n + ' unread message' + (n === 1 ? '' : 's'));
    } else {
      link.classList.remove('nhsuk-topnav__messages--unread', 'nhsuk-topnav__messages--new');
      if (badge) {
        badge.textContent = '';
        badge.hidden = true;
      }
      link.setAttribute('aria-label', 'Messages');
    }
    _lastUnreadCount = n;
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

  async function refreshUnreadBadge() {
    if (!global.NHSAuth || !NHSAuth.user) return;
    var link = document.getElementById('navMessagesLink');
    if (!link) return;

    var isHr = !!NHSAuth.user.premium;
    var url = isHr ? '/api/hr/messages/unread-count' : '/api/me/messages/unread-count';
    try {
      var res = await fetch(url, { credentials: 'include' });
      if (!res.ok) {
        applyUnreadVisual(link, 0);
        return;
      }
      var data = await res.json();
      applyUnreadVisual(link, Number(data.unread || 0));
    } catch (e) {
      applyUnreadVisual(link, 0);
    }
  }

  function notifyMessagesChanged() {
    _previewCache.at = 0;
    void refreshUnreadBadge();
    try {
      document.dispatchEvent(new CustomEvent('nhs-messages-changed'));
    } catch (e) {}
  }

  function wireUnreadPolling() {
    if (_unreadPollWired) return;
    _unreadPollWired = true;

    document.addEventListener('visibilitychange', function () {
      if (!document.hidden) void refreshUnreadBadge();
    });
    window.addEventListener('focus', function () {
      void refreshUnreadBadge();
    });
    document.addEventListener('nhs-messages-changed', function () {
      _previewCache.at = 0;
      void refreshUnreadBadge();
    });

    if (_unreadPollTimer) clearInterval(_unreadPollTimer);
    _unreadPollTimer = setInterval(function () {
      if (document.hidden) return;
      if (!global.NHSAuth || !NHSAuth.user) return;
      void refreshUnreadBadge();
    }, UNREAD_POLL_MS);
  }

  async function refreshNavAccount() {
    if (!global.NHSAuth) return;
    await NHSAuth.refresh();
    if (!NHSAuth.user) return;

    upgradeLegacyNavEmail();
    ensureMessagesPreviewUi();
    wireMessagesPreview();
    wireUnreadPolling();

    var nameEl = document.getElementById('navUserName');
    var link = document.getElementById('navMessagesLink');
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

    await refreshUnreadBadge();
  }

  function init() {
    upgradeLegacyNavEmail();
    ensureMessagesPreviewUi();
    wireMessagesPreview();
    wireUnreadPolling();
    void refreshNavAccount();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

  global.NHSNavAccount = {
    refresh: refreshNavAccount,
    refreshUnreadBadge: refreshUnreadBadge,
    notifyMessagesChanged: notifyMessagesChanged,
  };
})(typeof window !== 'undefined' ? window : globalThis);
