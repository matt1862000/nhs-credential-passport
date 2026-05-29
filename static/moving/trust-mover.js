/**
 * Trust move planner: loads /static/trust/config/{configId}.json and renders
 * mandatory list + wallet gap analysis via /api/me/trust-move/checklist-preview
 * (same matcher as trust requirements / compliance snapshot).
 */
(function () {
  /**
   * Map ODS code → config file ID (filename without .json).
   * Add a row here whenever a new trust config is added to /static/trust/config/.
   */
  var ODS_TO_CONFIG_ID = {
    RHQ: 'sheffield',
    TAH: 'sheffield-health-partnership',
    RXE: 'rotherham',
  };

  /**
   * Fallback: if no ODS code is known, try matching the typed name against
   * these substrings (lower-case).
   */
  var NAME_TO_CONFIG_ID = [
    { substr: 'sheffield teaching', id: 'sheffield' },
    { substr: 'sheffield health', id: 'sheffield-health-partnership' },
    { substr: 'social care nhs foundation', id: 'sheffield-health-partnership' },
    { substr: 'rotherham doncaster', id: 'rotherham' },
    { substr: 'south humber nhs foundation', id: 'rotherham' },
  ];

  var btnRefresh = document.getElementById('btnRefreshChecklist');
  var cache = {};
  var checklistReqSeq = 0;

  function escapeHtml(s) {
    if (s == null) return '';
    var d = document.createElement('div');
    d.textContent = s;
    return d.innerHTML;
  }

  function getJoinConfigId() {
    var ods = (document.getElementById('joinTrustOds') || {}).value || '';
    if (ods && ODS_TO_CONFIG_ID[ods.toUpperCase()]) return ODS_TO_CONFIG_ID[ods.toUpperCase()];
    var name = ((document.getElementById('joinTrustInput') || {}).value || '').trim().toLowerCase();
    for (var i = 0; i < NAME_TO_CONFIG_ID.length; i++) {
      if (name.indexOf(NAME_TO_CONFIG_ID[i].substr) !== -1) return NAME_TO_CONFIG_ID[i].id;
    }
    return null;
  }

  function portabilityBadge(portability) {
    if (portability === 'portable') return ' <span class="moving-tag tag-met" style="font-size:0.6875rem;">Portable</span>';
    if (portability === 'local_only') return ' <span class="moving-tag tag-miss" style="font-size:0.6875rem;">Local only</span>';
    if (portability === 'conditional') return ' <span class="moving-tag tag-partial" style="font-size:0.6875rem;">Conditional</span>';
    return '';
  }

  // Legacy fallback for older snapshots without a decision envelope.
  function legacyStatusCell(t) {
    var label = t.status_label || t.status || '—';
    var cls = 'tag-miss';
    if ((t.status_label || '').indexOf('Met') === 0) cls = 'tag-met';
    else if ((t.status_label || '').indexOf('Needs review') === 0) cls = 'tag-partial';
    return (
      '<span class="moving-tag ' + cls + '">' + escapeHtml(label) + '</span>' +
      (t.reason ? '<div class="moving-muted" style="margin-top:0.3rem;">' + escapeHtml(t.reason) + '</div>' : '')
    );
  }

  // Decision-support cell mirroring the doctor requirements page layout.
  function decisionCell(t) {
    if (!t.decision) return legacyStatusCell(t);

    var cls = 'moving-decision';
    var icon = '\u2753';
    var title = 'Decision pending';
    if (t.decision === 'MEETS') {
      cls += ' moving-decision--meets';
      icon = '\u2705';
      title = 'Meets requirement';
    } else if (t.decision === 'REQUIRES_REVIEW') {
      cls += ' moving-decision--review';
      icon = '\u26A0\uFE0F';
      title = 'Currently being reviewed by HR';
    } else {
      cls += ' moving-decision--fail';
      icon = '\u274C';
      title = 'Does not meet requirement';
    }

    // Doctor view, intentionally minimal — show ONCE, no repetition:
    //   1. Decision badge (the only thing the doctor acts on)
    //   2. Why, in plain English (match + validity)
    //   3. The actual record line from their wallet (for context)
    //
    // Deliberately omitted (HR-only context):
    //   - decision_confidence_label / reason  (duplicates the badge)
    //   - match_label chip  (duplicates the "exactly matches" sentence)
    //   - historical_acceptance_hint, decision_factors  (HR / audit)
    var titleHtml =
      '<p class="moving-decision__title"><span aria-hidden="true">' + icon +
      '</span><span>' + escapeHtml(title) + '</span></p>';

    var whyText = t.decision_reason_short || t.decision_reason;
    var whyHtml = whyText
      ? '<p class="moving-decision__why">' + escapeHtml(whyText) + '</p>'
      : '';

    var recordLine = '';
    if (t.module_name) {
      recordLine =
        '<p class="moving-record">From your training list: <strong>' +
        escapeHtml(t.module_name) + '</strong>' +
        (t.expiry_date ? ' &middot; expires ' + escapeHtml(t.expiry_date) : '') +
        (t.hr_status ? ' &middot; HR ' + escapeHtml(t.hr_status) : '') +
        '</p>';
    }

    return (
      '<div class="' + cls + '">' +
      titleHtml + whyHtml + recordLine +
      '</div>'
    );
  }

  function renderWalletPreview(preview) {
    var topics = (preview && preview.topics) || [];
    if (!topics.length) {
      return '<p class="moving-muted"><a href="/static/staff/#list">Add or import your previously completed training</a>.</p>';
    }

    var sum = preview.summary || {};
    var body = topics
      .map(function (t) {
        return (
          '<tr><td>' +
          escapeHtml(t.topic_name) +
          portabilityBadge(t.portability) +
          '</td><td>' +
          decisionCell(t) +
          '</td></tr>'
        );
      })
      .join('');

    var summary =
      '<p class="moving-gap-summary" role="status"><strong>Gap analysis (illustrative):</strong> ' +
      Number(sum.met || 0) +
      ' meet &middot; ' +
      Number(sum.needs_review || 0) +
      ' need review &middot; ' +
      Number(sum.gap || 0) +
      ' do not meet</p>';

    var recNote = preview.recognition_summary
      ? '<p class="moving-muted">' + escapeHtml(preview.recognition_summary) + '</p>'
      : '';

    return (
      summary +
      recNote +
      '<table class="moving-table"><thead><tr><th>Required topic (pack)</th><th>Engine assessment</th></tr></thead><tbody>' +
      body +
      '</tbody></table><p class="moving-muted moving-footnote">Green = likely meets requirement. Amber = needs HR review. Red = does not meet or expired. Not formal acceptance by your new trust.</p>'
    );
  }

  function render(cfg, preview) {
    var rows = (cfg.mandatory_examples || []).map(function (req) {
      return (
        '<tr><td>' +
        escapeHtml(req.label) +
        '</td><td>' +
        escapeHtml(req.category || '') +
        '</td></tr>'
      );
    }).join('');
    document.getElementById('movingMandatoryWrap').innerHTML =
      '<table class="moving-table"><thead><tr><th>Topic</th><th>Category</th></tr></thead><tbody>' +
      rows +
      '</tbody></table>';

    document.getElementById('movingWalletWrap').innerHTML = renderWalletPreview(preview);

    document.getElementById('movingResults').hidden = false;
    document.getElementById('movingResults').setAttribute('aria-hidden', 'false');
  }

  function loadConfig(configId) {
    if (cache[configId]) return Promise.resolve(cache[configId]);
    return fetch('/static/trust/config/' + encodeURIComponent(configId) + '.json')
      .then(function (r) {
        if (!r.ok) throw new Error('No checklist pack for this trust yet.');
        return r.json();
      })
      .then(function (j) {
        cache[configId] = j;
        return j;
      });
  }

  function loadChecklistPreview(configId) {
    return fetch(
      '/api/me/trust-move/checklist-preview?pack_id=' + encodeURIComponent(configId),
      { credentials: 'include' }
    ).then(function (r) {
      if (!r.ok) {
        return r.json().catch(function () { return {}; }).then(function (data) {
          throw new Error((data && data.detail) || 'Could not load checklist preview');
        });
      }
      return r.json();
    });
  }

  function isSignedInForPlanner() {
    return !!window.__nhsAuthUser;
  }

  function hideResults() {
    var results = document.getElementById('movingResults');
    if (results) {
      results.hidden = true;
      results.setAttribute('aria-hidden', 'true');
    }
  }

  function setError(msg) {
    var el = document.getElementById('movingError');
    if (el) el.textContent = msg || '';
  }

  function run() {
    if (!isSignedInForPlanner()) {
      setError('');
      hideResults();
      return;
    }
    var joinInput = document.getElementById('joinTrustInput');
    var joinText = joinInput ? joinInput.value.trim() : '';
    if (!joinText) {
      setError('');
      hideResults();
      return;
    }
    var configId = getJoinConfigId();
    if (!configId) {
      setError('No checklist pack is available for this trust yet.');
      hideResults();
      return;
    }

    setError('');
    var seq = ++checklistReqSeq;
    if (btnRefresh) {
      btnRefresh.disabled = true;
      btnRefresh.classList.add('is-loading');
      btnRefresh.setAttribute('aria-busy', 'true');
    }
    Promise.all([loadConfig(configId), loadChecklistPreview(configId)])
      .then(function (results) {
        if (seq !== checklistReqSeq) return;
        render(results[0], results[1].preview);
      })
      .catch(function (err) {
        if (seq !== checklistReqSeq) return;
        setError(err.message || String(err));
        hideResults();
      })
      .finally(function () {
        if (seq !== checklistReqSeq) return;
        if (btnRefresh) {
          btnRefresh.disabled = false;
          btnRefresh.classList.remove('is-loading');
          btnRefresh.removeAttribute('aria-busy');
        }
      });
  }

  if (btnRefresh) btnRefresh.addEventListener('click', run);
  window.addEventListener('nhs-wallet-updated', run);
  window.addEventListener('nhs-auth-changed', run);
  window.addEventListener('nhs-join-trust-selected', run);
})();
