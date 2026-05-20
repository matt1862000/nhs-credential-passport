/**
 * Trust move planner: loads /static/trust/config/{configId}.json and renders
 * mandatory list and wallet gap analysis.
 *
 * "I am leaving" = NHSAuth.user.current_trust (set by page boot).
 * "I am joining" = ODS autocomplete; ODS code mapped to config ID below.
 */
(function () {
  var STORAGE_KEY = 'nhs_credentials';

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
    /* fall back to name substring match */
    var name = ((document.getElementById('joinTrustInput') || {}).value || '').trim().toLowerCase();
    for (var i = 0; i < NAME_TO_CONFIG_ID.length; i++) {
      if (name.indexOf(NAME_TO_CONFIG_ID[i].substr) !== -1) return NAME_TO_CONFIG_ID[i].id;
    }
    return null;
  }

  function parseJwtPayload(jwt) {
    if (!jwt || typeof jwt !== 'string' || jwt.split('.').length < 2) return null;
    try {
      var b64 = jwt.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
      var pad = b64.length % 4 ? '='.repeat(4 - (b64.length % 4)) : '';
      var json = decodeURIComponent(escape(atob(b64 + pad)));
      return JSON.parse(json);
    } catch (e) {
      return null;
    }
  }

  function credMatchesRequirement(req, pl) {
    if (!pl) return false;
    var code = (pl.module_code || '').toLowerCase();
    var name = (pl.module_name || '').toLowerCase();
    var codes = req.match_module_codes || [];
    for (var i = 0; i < codes.length; i++) {
      if (code === String(codes[i]).toLowerCase()) return true;
    }
    var subs = req.match_name_substrings || [];
    for (var j = 0; j < subs.length; j++) {
      if (name.indexOf(String(subs[j]).toLowerCase()) !== -1) return true;
    }
    return false;
  }

  function credMatchesPartialOnly(req, pl) {
    if (!pl || credMatchesRequirement(req, pl)) return false;
    var codes = req.partial_module_codes || [];
    var code = (pl.module_code || '').toLowerCase();
    var k;
    for (k = 0; k < codes.length; k++) {
      if (code === String(codes[k]).toLowerCase()) return true;
    }
    var ps = req.partial_name_substrings || [];
    var name = (pl.module_name || '').toLowerCase();
    for (k = 0; k < ps.length; k++) {
      if (name.indexOf(String(ps[k]).toLowerCase()) !== -1) return true;
    }
    return false;
  }

  function isFromLeavingTrust(pl, rec) {
    if (!rec || !pl) return false;
    var n = ((pl.issuing_trust_name || '') + ' ' + (pl.issuing_trust_ods || '')).toLowerCase();
    var hints = rec.issuer_trust_name_hints || [];
    for (var i = 0; i < hints.length; i++) {
      if (n.indexOf(String(hints[i]).toLowerCase()) !== -1) return true;
    }
    var ods = rec.issuer_ods_hints || [];
    for (var j = 0; j < ods.length; j++) {
      if ((pl.issuing_trust_ods || '').toUpperCase() === String(ods[j]).toUpperCase()) return true;
    }
    return false;
  }

  function todayIso() {
    var d = new Date();
    return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
  }

  function notExpired(expiryDate) {
    if (!expiryDate) return true;
    return String(expiryDate) >= todayIso();
  }

  function walletTable(reqs, recHints) {
    var list = [];
    try {
      list = JSON.parse(localStorage.getItem(STORAGE_KEY) || '[]');
    } catch (e) {
      list = [];
    }
    var payloads = [];
    list.forEach(function (c) {
      var pl = parseJwtPayload(c.jwt);
      if (pl) payloads.push({ wallet: c, pl: pl });
    });

    if (payloads.length === 0) {
      return '<p class="moving-muted"><a href="/static/staff/#list">Add or import your previously completed training</a>.</p>';
    }

    var nMet = 0;
    var nPartial = 0;
    var nGap = 0;
    var body = (reqs || [])
      .map(function (req) {
        var best = null;
        var bestPl = null;
        var i;
        for (i = 0; i < payloads.length; i++) {
          if (credMatchesRequirement(req, payloads[i].pl)) {
            best = payloads[i].wallet;
            bestPl = payloads[i].pl;
            break;
          }
        }
        var status, tagClass, detail;
        if (best && bestPl) {
          var ok = notExpired(best.expiry_date);
          var fromLeave = recHints && isFromLeavingTrust(bestPl, recHints);
          if (!ok) {
            status = 'Expired on your list';
            tagClass = 'tag-miss';
            nGap++;
          } else {
            status = fromLeave ? 'Met (issuer matches "leaving" trust hints)' : 'Met';
            tagClass = 'tag-met';
            nMet++;
          }
          detail =
            escapeHtml(bestPl.module_name || '') +
            ' · expires ' +
            escapeHtml(best.expiry_date || '') +
            ' · issued by ' +
            escapeHtml(bestPl.issuing_trust_name || bestPl.issuing_trust_ods || '?');
        } else {
          var part = null;
          var partPl = null;
          for (i = 0; i < payloads.length; i++) {
            if (credMatchesPartialOnly(req, payloads[i].pl)) {
              part = payloads[i].wallet;
              partPl = payloads[i].pl;
              break;
            }
          }
          if (part && partPl) {
            var okp = notExpired(part.expiry_date);
            if (!okp) {
              status = 'Partial — expired';
              tagClass = 'tag-miss';
              nGap++;
            } else {
              status = 'Partial — related / lower level only';
              tagClass = 'tag-partial';
              nPartial++;
            }
            var hint = req.partial_hint ? escapeHtml(req.partial_hint) + ' ' : '';
            detail =
              hint +
              '<span class="moving-muted">' +
              escapeHtml(partPl.module_name || '') +
              ' · expires ' +
              escapeHtml(part.expiry_date || '') +
              '</span>';
          } else {
            status = 'Gap — not in your list';
            tagClass = 'tag-miss';
            nGap++;
            detail = '—';
          }
        }
        return (
          '<tr><td>' +
          escapeHtml(req.label) +
          '</td><td><span class="moving-tag ' +
          tagClass +
          '">' +
          escapeHtml(status) +
          '</span></td><td>' +
          detail +
          '</td></tr>'
        );
      })
      .join('');

    var summary =
      '<p class="moving-gap-summary" role="status"><strong>Gap analysis (illustrative):</strong> ' +
      nMet +
      ' met · ' +
      nPartial +
      ' partial · ' +
      nGap +
      ' gap or expired</p>';

    return (
      summary +
      '<table class="moving-table"><thead><tr><th>Required topic (pack)</th><th>Your training list</th><th>Detail</th></tr></thead><tbody>' +
      body +
      '</tbody></table><p class="moving-muted moving-footnote">Green = plausible match to this pack. Amber = related training that may not meet the stated requirement. Red = missing or expired. Not formal acceptance by your new trust.</p>'
    );
  }

  function getRecognitionHints(cfg) {
    var map = cfg.recognition_when_joining || {};
    return map._default || {};
  }

  function render(cfg) {
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
      '<table class="moving-table"><thead><tr><th>Topic</th><th>Category</th></tr></thead><tbody>' + rows + '</tbody></table>';

    var recHints = getRecognitionHints(cfg);
    document.getElementById('movingWalletWrap').innerHTML = walletTable(cfg.mandatory_examples || [], recHints);

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
    loadConfig(configId)
      .then(function (cfg) {
        if (seq !== checklistReqSeq) return;
        render(cfg);
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
