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

  function tagClassForTopic(t) {
    if (t.status === 'expiring') return 'tag-partial';
    var label = t.status_label || '';
    if (label.indexOf('Met') === 0) return 'tag-met';
    if (label === 'Needs review' || label.indexOf('Needs review') === 0) return 'tag-partial';
    return 'tag-miss';
  }

  function statusLabelForTopic(t) {
    return t.status_label || t.status || '—';
  }

  function portabilityBadge(portability) {
    if (portability === 'portable') return ' <span class="moving-tag tag-met" style="font-size:0.6875rem;">Portable</span>';
    if (portability === 'local_only') return ' <span class="moving-tag tag-miss" style="font-size:0.6875rem;">Local only</span>';
    if (portability === 'conditional') return ' <span class="moving-tag tag-partial" style="font-size:0.6875rem;">Conditional</span>';
    return '';
  }

  function renderWalletPreview(preview) {
    var topics = (preview && preview.topics) || [];
    if (!topics.length) {
      return '<p class="moving-muted"><a href="/static/staff/#list">Add or import your previously completed training</a>.</p>';
    }

    var sum = preview.summary || {};
    var body = topics
      .map(function (t) {
        var tagClass = tagClassForTopic(t);
        var label = statusLabelForTopic(t);
        var detail = t.reason ? escapeHtml(t.reason) : '—';
        if (t.module_name) {
          detail +=
            '<br><span class="moving-muted">' +
            escapeHtml(t.module_name) +
            (t.expiry_date ? ' · expires ' + escapeHtml(t.expiry_date) : '') +
            (t.hr_status ? ' · HR ' + escapeHtml(t.hr_status) : '') +
            '</span>';
        }
        if (t.match_label) {
          detail +=
            '<br><span class="moving-muted"><strong>Match:</strong> ' +
            escapeHtml(t.match_label) +
            '</span>';
        }
        if (t.decision_reason) {
          detail +=
            '<br><span class="moving-muted"><strong>Assessment:</strong> ' +
            escapeHtml(t.decision_reason) +
            '</span>';
        }
        if (t.historical_acceptance_hint) {
          detail +=
            '<br><span class="moving-muted">' + escapeHtml(t.historical_acceptance_hint) + '</span>';
        }
        return (
          '<tr><td>' +
          escapeHtml(t.topic_name) +
          portabilityBadge(t.portability) +
          '</td><td><span class="moving-tag ' +
          tagClass +
          '">' +
          escapeHtml(label) +
          '</span></td><td>' +
          detail +
          '</td></tr>'
        );
      })
      .join('');

    var summary =
      '<p class="moving-gap-summary" role="status"><strong>Gap analysis (illustrative):</strong> ' +
      Number(sum.met || 0) +
      ' met · ' +
      Number(sum.needs_review || 0) +
      ' need review · ' +
      Number(sum.gap || 0) +
      ' gap or expired</p>';

    var recNote = preview.recognition_summary
      ? '<p class="moving-muted">' + escapeHtml(preview.recognition_summary) + '</p>'
      : '';

    return (
      summary +
      recNote +
      '<table class="moving-table"><thead><tr><th>Required topic (pack)</th><th>Your training list</th><th>Detail</th></tr></thead><tbody>' +
      body +
      '</tbody></table><p class="moving-muted moving-footnote">Green = exact or alias match. Amber = partial match or expiring soon — confirm with HR. Red = missing or expired. Not formal acceptance by your new trust.</p>'
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
