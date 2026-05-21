/**
 * Shared messaging UI: attachments, bubble rendering, send (JSON or multipart).
 */
(function (global) {
  var MAX_FILES = 5;
  var pendingFiles = [];

  function esc(s) {
    var d = document.createElement('div');
    d.textContent = s || '';
    return d.innerHTML;
  }

  function formatBytes(n) {
    var b = Number(n) || 0;
    if (b < 1024) return b + ' B';
    if (b < 1024 * 1024) return (b / 1024).toFixed(1) + ' KB';
    return (b / (1024 * 1024)).toFixed(1) + ' MB';
  }

  function fmtTime(iso) {
    if (!iso) return '';
    var d = new Date(iso + (iso.endsWith('Z') ? '' : 'Z'));
    return isNaN(d) ? iso.slice(0, 16).replace('T', ' ') :
      d.toLocaleString('en-GB', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
  }

  function attachmentUrl(id) {
    return '/api/messages/attachments/' + encodeURIComponent(String(id));
  }

  function renderAttachmentsHtml(attachments, mine) {
    if (!attachments || !attachments.length) return '';
    var parts = attachments.map(function (a) {
      var url = attachmentUrl(a.id);
      var ct = (a.content_type || '').toLowerCase();
      var name = esc(a.filename || 'file');
      if (ct.indexOf('image/') === 0) {
        return '<a class="msg-attach-img-wrap" href="' + url + '" target="_blank" rel="noopener">' +
          '<img class="msg-attach-thumb" src="' + url + '" alt="' + name + '">' +
          '</a>';
      }
      return '<a class="msg-attach-link" href="' + url + '" download>' + name + '</a>' +
        ' <span class="msg-attach-size">(' + esc(formatBytes(a.size_bytes)) + ')</span>';
    });
    return '<div class="msg-bubble-attachments">' + parts.join('') + '</div>';
  }

  function renderBubbles(container, messages, myId, nameForOther) {
    if (!container) return;
    if (!messages || !messages.length) {
      container.innerHTML = '<p class="msg-empty">No messages yet. Say hello!</p>';
      return;
    }
    container.innerHTML = messages.map(function (m) {
      var mine = String(m.sender_user_id) === String(myId);
      var cls = mine ? 'msg-bubble--mine' : 'msg-bubble--theirs';
      var name = mine ? 'You' : esc(
        m.sender_name || m.sender_email || nameForOther || 'Contact'
      );
      var bodyHtml = (m.body && String(m.body).trim())
        ? '<div class="msg-bubble-text">' + esc(m.body) + '</div>'
        : '';
      var attHtml = renderAttachmentsHtml(m.attachments, mine);
      return (
        '<div class="msg-bubble ' + cls + '">' +
          bodyHtml + attHtml +
          '<div class="msg-bubble-meta">' + name + ' · ' + esc(fmtTime(m.sent_at)) + '</div>' +
        '</div>'
      );
    }).join('');
    container.scrollTop = container.scrollHeight;
  }

  function renderPendingList(listEl) {
    if (!listEl) return;
    if (!pendingFiles.length) {
      listEl.hidden = true;
      listEl.innerHTML = '';
      return;
    }
    listEl.hidden = false;
    listEl.innerHTML = pendingFiles.map(function (f, i) {
      return (
        '<li class="msg-pending-item">' +
          '<span class="msg-pending-name">' + esc(f.name) + '</span>' +
          ' <span class="msg-pending-size">(' + esc(formatBytes(f.size)) + ')</span>' +
          ' <button type="button" class="msg-pending-remove" data-pending-idx="' + i + '" aria-label="Remove ' + esc(f.name) + '">×</button>' +
        '</li>'
      );
    }).join('');
  }

  function clearPending(fileInput, listEl) {
    pendingFiles = [];
    if (fileInput) fileInput.value = '';
    renderPendingList(listEl);
  }

  function addPendingFiles(fileList, fileInput, listEl) {
    if (!fileList || !fileList.length) return;
    var room = MAX_FILES - pendingFiles.length;
    if (room <= 0) {
      alert('Maximum ' + MAX_FILES + ' files per message. Remove one to add another.');
      return;
    }
    for (var i = 0; i < fileList.length && pendingFiles.length < MAX_FILES; i++) {
      pendingFiles.push(fileList[i]);
    }
    if (fileList.length > room) {
      alert('Only ' + MAX_FILES + ' files allowed per message. Extra files were not added.');
    }
    if (fileInput) fileInput.value = '';
    renderPendingList(listEl);
  }

  function bindCompose(fileInputId, attachBtnId, pendingListId) {
    var fileInput = document.getElementById(fileInputId);
    var attachBtn = document.getElementById(attachBtnId);
    var listEl = document.getElementById(pendingListId);
    if (attachBtn && fileInput) {
      attachBtn.addEventListener('click', function () { fileInput.click(); });
    }
    if (fileInput) {
      fileInput.addEventListener('change', function () {
        addPendingFiles(fileInput.files, fileInput, listEl);
      });
    }
    if (listEl) {
      listEl.addEventListener('click', function (e) {
        var btn = e.target.closest('[data-pending-idx]');
        if (!btn) return;
        var idx = parseInt(btn.getAttribute('data-pending-idx'), 10);
        if (!isNaN(idx)) {
          pendingFiles.splice(idx, 1);
          renderPendingList(listEl);
        }
      });
    }
    return {
      clear: function () { clearPending(fileInput, listEl); },
      getPending: function () { return pendingFiles.slice(); },
    };
  }

  async function sendMessage(sendUrl, text, files) {
    var res;
    if (files && files.length) {
      var fd = new FormData();
      fd.append('body', text || '');
      files.forEach(function (f) { fd.append('files', f, f.name); });
      res = await fetch(sendUrl, { method: 'POST', credentials: 'include', body: fd });
    } else {
      res = await fetch(sendUrl, {
        method: 'POST',
        credentials: 'include',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ body: text }),
      });
    }
    var payload = await res.text();
    var data = null;
    try { data = payload ? JSON.parse(payload) : null; } catch (e) {}
    if (!res.ok) {
      var detail = data && data.detail;
      if (Array.isArray(detail)) {
        detail = detail.map(function (d) { return d.msg || d; }).join('; ');
      }
      throw new Error(detail || payload || res.statusText);
    }
    return data;
  }

  function canSend(text, files) {
    return !!(String(text || '').trim() || (files && files.length));
  }

  global.NHSMessages = {
    esc: esc,
    fmtTime: fmtTime,
    formatBytes: formatBytes,
    renderBubbles: renderBubbles,
    bindCompose: bindCompose,
    sendMessage: sendMessage,
    canSend: canSend,
    MAX_FILES: MAX_FILES,
  };
})(typeof window !== 'undefined' ? window : global);
