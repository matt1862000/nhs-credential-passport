/**
 * Header account strip: display name, HR verify bell (premium), messages link with badge,
 * hover previews, and background polling.
 */
(function (global) {
  var ENVELOPE_SVG =
    '<svg class="nhsuk-topnav__envelope" width="22" height="22" viewBox="0 0 24 24" aria-hidden="true" focusable="false">' +
    '<path fill="currentColor" d="M20 4H4c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V6c0-1.1-.9-2-2-2zm0 4l-8 5-8-5V6l8 5 8-5v2z"/></svg>';

  var ENVELOPE_SVG_UNREAD =
    '<svg class="nhsuk-topnav__envelope" width="22" height="22" viewBox="0 0 24 24" aria-hidden="true" focusable="false">' +
    '<path fill="currentColor" d="M20 4H4c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V6c0-1.1-.9-2-2-2zm-1.2 4.2l-6.8 4.25L5.2 8.2V6l6.8 4.25L18.8 6v2.2z"/>' +
    '<circle class="nhsuk-topnav__envelope-dot" cx="18.5" cy="7" r="3.25" fill="#d5281b" stroke="#fff" stroke-width="1.25"/></svg>';

  var BELL_SVG =
    '<svg class="nhsuk-topnav__bell" width="22" height="22" viewBox="0 0 24 24" aria-hidden="true" focusable="false">' +
    '<path fill="currentColor" d="M12 22a2 2 0 0 0 2-2h-4a2 2 0 0 0 2 2zm7-6v-5c0-3.07-1.64-5.64-4.5-6.32V4.5C14.5 3.67 13.83 3 13 3s-1.5.67-1.5 1.5v.18C8.64 5.36 7 7.92 7 11v5l-2 2v1h16v-1l-2-2z"/></svg>';

  var BELL_SVG_PENDING =
    '<svg class="nhsuk-topnav__bell" width="22" height="22" viewBox="0 0 24 24" aria-hidden="true" focusable="false">' +
    '<path fill="currentColor" d="M12 22a2 2 0 0 0 2-2h-4a2 2 0 0 0 2 2zm7-6v-5c0-3.07-1.64-5.64-4.5-6.32V4.5C14.5 3.67 13.83 3 13 3s-1.5.67-1.5 1.5v.18C8.64 5.36 7 7.92 7 11v5l-2 2v1h16v-1l-2-2z"/>' +
    '<circle class="nhsuk-topnav__bell-dot" cx="17.5" cy="6.5" r="3.25" fill="#d5281b" stroke="#fff" stroke-width="1.25"/></svg>';

  var PREVIEW_LIMIT = 5;
  var PREVIEW_CACHE_MS = 20000;
  var UNREAD_POLL_MS = 15000;
  var HR_INBOX_PATH = '/static/hr/';
  var _previewCache = { at: 0, key: '', conversations: [] };
  var _verifyPreviewCache = { at: 0, groups: [] };
  var _previewHideTimer = null;
  var _previewShowTimer = null;
  var _previewWired = false;
  var _verifyPreviewHideTimer = null;
  var _verifyPreviewShowTimer = null;
  var _verifyPreviewWired = false;
  var _unreadPollTimer = null;
  var _unreadPollWired = false;
  var _lastUnreadCount = 0;
  var _lastVerifyPendingCount = 0;
  var _newMsgFlashTimer = null;
  var _newVerifyFlashTimer = null;

  function esc(s) {
    var d = document.createElement('div');
    d.textContent = s == null ? '' : String(s);
    return d.innerHTML;
  }

  function verifyBellInnerHtml() {
    return (
      '<a href="' +
      HR_INBOX_PATH +
      '" class="nhsuk-topnav__messages nhsuk-topnav__verify" id="navVerifyLink" aria-label="Training to verify">' +
      BELL_SVG +
      '<span class="nhsuk-topnav__msg-badge" id="navVerifyBadge" hidden aria-live="polite"></span>' +
      '</a>' +
      '<div class="nhsuk-topnav__msg-preview" id="navVerifyPreview" role="tooltip" hidden>' +
      '<p class="nhsuk-topnav__msg-preview-head">Awaiting verification</p>' +
      '<div class="nhsuk-topnav__msg-preview-body" id="navVerifyPreviewBody"></div>' +
      '<a class="nhsuk-topnav__msg-preview-foot" id="navVerifyPreviewAll" href="' +
      HR_INBOX_PATH +
      '">Open verification inbox</a>' +
      '</div>'
    );
  }

  function accountMarkup() {
    return (
      '<div class="nhsuk-topnav__account" id="navAccount">' +
      '<span class="nhsuk-topnav__name" id="navUserName">&nbsp;</span>' +
      '<div class="nhsuk-topnav__account-tools" id="navAccountTools">' +
      '<div class="nhsuk-topnav__verify-wrap" id="navVerifyWrap" hidden>' +
      verifyBellInnerHtml() +
      '</div>' +
      '<div class="nhsuk-topnav__messages-wrap" id="navMessagesWrap">' +
      '<a href="/static/messages/" class="nhsuk-topnav__messages" id="navMessagesLink" aria-label="Messages">' +
      ENVELOPE_SVG +
      '<span class="nhsuk-topnav__msg-badge" id="navMsgBadge" hidden aria-live="polite"></span>' +
      '</a>' +
      '<div class="nhsuk-topnav__msg-preview" id="navMessagesPreview" role="tooltip" hidden>' +
      '<p class="nhsuk-topnav__msg-preview-head">Messages</p>' +
      '<div class="nhsuk-topnav__msg-preview-body" id="navMessagesPreviewBody"></div>' +
      '<a class="nhsuk-topnav__msg-preview-foot" id="navMessagesPreviewAll" href="/static/messages/">View all messages</a>' +
      '</div></div></div></div>'
    );
  }

  function ensureAccountToolsLayout() {
    var account = document.getElementById('navAccount');
    if (!account || document.getElementById('navAccountTools')) return;
    var nameEl = document.getElementById('navUserName');
    var tools = document.createElement('div');
    tools.className = 'nhsuk-topnav__account-tools';
    tools.id = 'navAccountTools';
    var toMove = [];
    for (var i = 0; i < account.childNodes.length; i++) {
      var ch = account.childNodes[i];
      if (ch !== nameEl) toMove.push(ch);
    }
    toMove.forEach(function (ch) {
      tools.appendChild(ch);
    });
    if (nameEl) account.insertBefore(tools, nameEl.nextSibling);
    else account.appendChild(tools);
  }

  function ensureVerifyBellUi() {
    ensureAccountToolsLayout();
    var tools = document.getElementById('navAccountTools');
    if (!tools || document.getElementById('navVerifyWrap')) return;
    var wrap = document.createElement('div');
    wrap.className = 'nhsuk-topnav__verify-wrap';
    wrap.id = 'navVerifyWrap';
    wrap.hidden = true;
    wrap.innerHTML = verifyBellInnerHtml();
    tools.insertBefore(wrap, tools.firstChild);
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
    ensureAccountToolsLayout();
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

    if (isHr) {
      conversations = conversations.filter(function (c) {
        return Number(c.unread_count || 0) > 0;
      });
    }

    if (!conversations.length) {
      body.innerHTML = isHr
        ? '<p class="nhsuk-topnav__msg-preview-empty">No unread messages. Open Messages to search clinicians.</p>'
        : '<p class="nhsuk-topnav__msg-preview-empty">No conversations yet.</p>';
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

  function sessionsNeedingVerify(sessions) {
    return (sessions || []).filter(function (s) {
      return String(s.share_kind || 'review').toLowerCase() !== 'portfolio' && Number(s.pending_count || 0) > 0;
    });
  }

  function aggregateDoctorGroups(sessions) {
    var m = Object.create(null);
    sessions.forEach(function (s) {
      var id = s.doctor_user_id;
      var key = id != null && id !== '' ? 'u:' + String(id) : 'e:' + String((s.doctor_email || '').toLowerCase());
      if (!m[key]) {
        m[key] = {
          doctor_user_id: id,
          doctor_email: s.doctor_email,
          doctor_name: s.doctor_name,
          doctor_gmc: s.doctor_gmc,
          doctor_trust: s.doctor_trust,
          sessions: [],
        };
      }
      m[key].sessions.push(s);
    });
    return Object.keys(m)
      .map(function (key) {
        var g = m[key];
        var sess = g.sessions;
        var pending = sess.reduce(function (a, x) {
          return a + Number(x.pending_count || 0);
        }, 0);
        var latest = sess
          .map(function (x) {
            return x.created_at;
          })
          .sort()
          .slice(-1)[0];
        return {
          doctor_user_id: g.doctor_user_id,
          doctor_email: g.doctor_email,
          doctor_name: g.doctor_name,
          doctor_gmc: g.doctor_gmc,
          doctor_trust: g.doctor_trust,
          pending_count: pending,
          created_at: latest,
          sessions: sess,
        };
      })
      .sort(function (a, b) {
        return String(b.created_at || '').localeCompare(String(a.created_at || ''));
      });
  }

  function doctorGroupTitle(g) {
    return (g.doctor_name && String(g.doctor_name).trim()) || g.doctor_email || 'Clinician';
  }

  function reviewHrefForGroup(g) {
    if (g.doctor_user_id != null && g.doctor_user_id !== '') {
      return HR_INBOX_PATH + '?doctor=' + encodeURIComponent(String(g.doctor_user_id));
    }
    var sid = g.sessions && g.sessions[0] && g.sessions[0].session_id;
    return HR_INBOX_PATH + (sid ? '?session=' + encodeURIComponent(String(sid)) : '');
  }

  function setBellGraphic(link, hasPending) {
    if (!link) return;
    var badge = link.querySelector('#navVerifyBadge') || link.querySelector('.nhsuk-topnav__msg-badge');
    var badgeHtml = badge ? badge.outerHTML : '';
    link.innerHTML = (hasPending ? BELL_SVG_PENDING : BELL_SVG) + badgeHtml;
  }

  function applyVerifyVisual(link, wrap, count) {
    if (!link) return;
    var n = Number(count || 0);
    var hadPending = link.classList.contains('nhsuk-topnav__messages--unread');
    if ((n > 0) !== hadPending) {
      setBellGraphic(link, n > 0);
    }
    var badge = link.querySelector('.nhsuk-topnav__msg-badge');
    if (n > 0) {
      link.classList.add('nhsuk-topnav__messages--unread');
      if (n > _lastVerifyPendingCount || (!hadPending && n > 0)) {
        link.classList.add('nhsuk-topnav__messages--new');
        if (_newVerifyFlashTimer) clearTimeout(_newVerifyFlashTimer);
        _newVerifyFlashTimer = setTimeout(function () {
          link.classList.remove('nhsuk-topnav__messages--new');
          _newVerifyFlashTimer = null;
        }, 2800);
      }
      if (badge) {
        badge.textContent = n > 99 ? '99+' : String(n);
        badge.hidden = false;
      }
      link.setAttribute(
        'aria-label',
        'Training to verify, ' + n + ' record' + (n === 1 ? '' : 's') + ' awaiting verification'
      );
      if (wrap) wrap.hidden = false;
    } else {
      link.classList.remove('nhsuk-topnav__messages--unread', 'nhsuk-topnav__messages--new');
      if (badge) {
        badge.textContent = '';
        badge.hidden = true;
      }
      link.setAttribute('aria-label', 'Training to verify');
      if (wrap) wrap.hidden = true;
    }
    _lastVerifyPendingCount = n;
  }

  function renderVerifyPreviewBody(groups) {
    var body = document.getElementById('navVerifyPreviewBody');
    var foot = document.getElementById('navVerifyPreviewAll');
    if (foot) foot.href = HR_INBOX_PATH;
    if (!body) return;

    if (!groups.length) {
      body.innerHTML = '<p class="nhsuk-topnav__msg-preview-empty">Nothing awaiting verification.</p>';
      return;
    }

    body.innerHTML = groups
      .slice(0, PREVIEW_LIMIT)
      .map(function (g) {
        var pending = Number(g.pending_count || 0);
        var href = reviewHrefForGroup(g);
        var badge =
          pending > 0
            ? '<span class="nhsuk-topnav__msg-preview-unread">' +
              esc(pending > 99 ? '99+' : String(pending)) +
              '</span>'
            : '';
        var time = fmtPreviewTime(g.created_at);
        var meta = time ? '<span class="nhsuk-topnav__msg-preview-time">' + esc(time) + '</span>' : '';
        var snippet =
          pending === 1
            ? '1 record pending verification'
            : String(pending) + ' records pending verification';
        if (g.doctor_gmc) snippet += ' · GMC ' + String(g.doctor_gmc);
        return (
          '<a class="nhsuk-topnav__msg-preview-item nhsuk-topnav__msg-preview-item--unread" href="' +
          esc(href) +
          '">' +
          '<span class="nhsuk-topnav__msg-preview-title">' +
          esc(doctorGroupTitle(g)) +
          badge +
          '</span>' +
          '<span class="nhsuk-topnav__msg-preview-snippet">' +
          esc(snippet) +
          '</span>' +
          meta +
          '</a>'
        );
      })
      .join('');
  }

  async function fetchVerifyPreviewGroups() {
    var now = Date.now();
    if (now - _verifyPreviewCache.at < PREVIEW_CACHE_MS) {
      return _verifyPreviewCache.groups;
    }
    var res = await fetch('/api/hr/shares?limit=200', { credentials: 'include' });
    if (!res.ok) throw new Error('Could not load verification inbox');
    var data = await res.json();
    var groups = aggregateDoctorGroups(sessionsNeedingVerify(data.sessions || []));
    _verifyPreviewCache = { at: now, groups: groups };
    return groups;
  }

  function hideVerifyPreview() {
    var pop = document.getElementById('navVerifyPreview');
    var link = document.getElementById('navVerifyLink');
    if (pop) pop.hidden = true;
    if (link) link.removeAttribute('aria-describedby');
  }

  function showVerifyPreview() {
    var pop = document.getElementById('navVerifyPreview');
    var link = document.getElementById('navVerifyLink');
    if (!pop) return;
    pop.hidden = false;
    if (link) link.setAttribute('aria-describedby', 'navVerifyPreview');
  }

  async function openVerifyPreview() {
    if (!global.NHSAuth || !NHSAuth.user || !NHSAuth.user.premium) return;
    var body = document.getElementById('navVerifyPreviewBody');
    if (body) {
      body.innerHTML = '<p class="nhsuk-topnav__msg-preview-loading">Loading…</p>';
    }
    showVerifyPreview();
    try {
      var groups = await fetchVerifyPreviewGroups();
      renderVerifyPreviewBody(groups);
    } catch (e) {
      if (body) {
        body.innerHTML = '<p class="nhsuk-topnav__msg-preview-empty">Could not load preview.</p>';
      }
    }
  }

  function scheduleShowVerifyPreview() {
    if (_verifyPreviewHideTimer) {
      clearTimeout(_verifyPreviewHideTimer);
      _verifyPreviewHideTimer = null;
    }
    if (_verifyPreviewShowTimer) clearTimeout(_verifyPreviewShowTimer);
    _verifyPreviewShowTimer = setTimeout(function () {
      _verifyPreviewShowTimer = null;
      void openVerifyPreview();
    }, 280);
  }

  function scheduleHideVerifyPreview() {
    if (_verifyPreviewShowTimer) {
      clearTimeout(_verifyPreviewShowTimer);
      _verifyPreviewShowTimer = null;
    }
    if (_verifyPreviewHideTimer) clearTimeout(_verifyPreviewHideTimer);
    _verifyPreviewHideTimer = setTimeout(function () {
      _verifyPreviewHideTimer = null;
      hideVerifyPreview();
    }, 220);
  }

  function wireVerifyPreview() {
    if (_verifyPreviewWired) return;
    var wrap = document.getElementById('navVerifyWrap');
    if (!wrap) return;
    _verifyPreviewWired = true;

    wrap.addEventListener('mouseenter', scheduleShowVerifyPreview);
    wrap.addEventListener('mouseleave', scheduleHideVerifyPreview);
    wrap.addEventListener('focusin', scheduleShowVerifyPreview);
    wrap.addEventListener('focusout', function (e) {
      if (wrap.contains(e.relatedTarget)) return;
      scheduleHideVerifyPreview();
    });

    var pop = document.getElementById('navVerifyPreview');
    if (pop) {
      pop.addEventListener('mouseenter', function () {
        if (_verifyPreviewHideTimer) {
          clearTimeout(_verifyPreviewHideTimer);
          _verifyPreviewHideTimer = null;
        }
      });
      pop.addEventListener('mouseleave', scheduleHideVerifyPreview);
    }
  }

  async function refreshVerifyBadge() {
    var wrap = document.getElementById('navVerifyWrap');
    var link = document.getElementById('navVerifyLink');
    if (!wrap || !link) return;
    if (!global.NHSAuth || !NHSAuth.user || !NHSAuth.user.premium) {
      wrap.hidden = true;
      applyVerifyVisual(link, wrap, 0);
      return;
    }
    try {
      var res = await fetch('/api/hr/shares?limit=200', { credentials: 'include' });
      if (!res.ok) {
        applyVerifyVisual(link, wrap, 0);
        return;
      }
      var data = await res.json();
      var pendingSessions = sessionsNeedingVerify(data.sessions || []);
      var total = pendingSessions.reduce(function (a, s) {
        return a + Number(s.pending_count || 0);
      }, 0);
      applyVerifyVisual(link, wrap, total);
      if (window.location.pathname.indexOf('/static/hr') === 0) {
        link.setAttribute('aria-current', 'page');
      } else {
        link.removeAttribute('aria-current');
      }
    } catch (e) {
      applyVerifyVisual(link, wrap, 0);
    }
  }

  function notifyVerifyInboxChanged() {
    _verifyPreviewCache.at = 0;
    void refreshVerifyBadge();
    try {
      document.dispatchEvent(new CustomEvent('nhs-verify-inbox-changed'));
    } catch (e) {}
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
      if (!document.hidden) {
        void refreshUnreadBadge();
        if (global.NHSAuth && NHSAuth.user && NHSAuth.user.premium) void refreshVerifyBadge();
      }
    });
    window.addEventListener('focus', function () {
      void refreshUnreadBadge();
      if (global.NHSAuth && NHSAuth.user && NHSAuth.user.premium) void refreshVerifyBadge();
    });
    document.addEventListener('nhs-messages-changed', function () {
      _previewCache.at = 0;
      void refreshUnreadBadge();
    });
    document.addEventListener('nhs-verify-inbox-changed', function () {
      _verifyPreviewCache.at = 0;
      void refreshVerifyBadge();
    });

    if (_unreadPollTimer) clearInterval(_unreadPollTimer);
    _unreadPollTimer = setInterval(function () {
      if (document.hidden) return;
      if (!global.NHSAuth || !NHSAuth.user) return;
      void refreshUnreadBadge();
      if (NHSAuth.user.premium) void refreshVerifyBadge();
    }, UNREAD_POLL_MS);
  }

  async function refreshNavAccount() {
    if (!global.NHSAuth) return;
    await NHSAuth.refresh();
    if (!NHSAuth.user) return;

    upgradeLegacyNavEmail();
    ensureAccountToolsLayout();
    ensureVerifyBellUi();
    ensureMessagesPreviewUi();
    wireVerifyPreview();
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
    refreshVerifyBadge: refreshVerifyBadge,
    notifyMessagesChanged: notifyMessagesChanged,
    notifyVerifyInboxChanged: notifyVerifyInboxChanged,
  };
})(typeof window !== 'undefined' ? window : globalThis);
