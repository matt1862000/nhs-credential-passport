/**
 * Trust move planner: loads /static/trust/config/{join}.json and renders
 * mandatory list, recognition (by leaving trust), and wallet match (localStorage).
 */
(function () {
  var STORAGE_KEY = 'nhs_credentials';
  var JOIN_OPTIONS = [
    { id: 'sheffield', label: 'Sheffield Teaching Hospitals NHS FT (pilot example)' },
    { id: 'example-north', label: 'Example Northern trust (placeholder)' },
  ];
  var LEAVE_OPTIONS = [
    { id: 'rotherham', label: 'The Rotherham NHS Foundation Trust (example)' },
    { id: 'other', label: 'Another trust (generic guidance)' },
  ];

    var joinSel = document.getElementById('joinTrust');
    var leaveSel = document.getElementById('leaveTrust');
    var btnRefresh = document.getElementById('btnRefreshChecklist');
    var cache = {};
    var checklistReqSeq = 0;

  function escapeHtml(s) {
    if (s == null) return '';
    var d = document.createElement('div');
    d.textContent = s;
    return d.innerHTML;
  }

  function fillSelect(sel, options) {
    sel.innerHTML = options.map(function (o) {
      return '<option value="' + escapeHtml(o.id) + '">' + escapeHtml(o.label) + '</option>';
    }).join('');
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
            status = fromLeave ? 'Met (issuer matches “leaving” trust hints)' : 'Met';
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

  function getRecognitionHints(cfg, leaveId) {
    var map = cfg.recognition_when_joining || {};
    return map[leaveId === 'other' ? '_default' : leaveId] || map._default || {};
  }

  function render(cfg, joinId, leaveId) {
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

    var recHints = getRecognitionHints(cfg, leaveId);
    document.getElementById('movingWalletWrap').innerHTML = walletTable(cfg.mandatory_examples || [], recHints);

    document.getElementById('movingResults').hidden = false;
    document.getElementById('movingResults').setAttribute('aria-hidden', 'false');
  }

  function loadConfig(joinId) {
    if (cache[joinId]) return Promise.resolve(cache[joinId]);
    return fetch('/static/trust/config/' + encodeURIComponent(joinId) + '.json')
      .then(function (r) {
        if (!r.ok) throw new Error('No checklist pack for this trust yet (' + r.status + ').');
        return r.json();
      })
      .then(function (j) {
        cache[joinId] = j;
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

  function run() {
    if (!isSignedInForPlanner()) {
      document.getElementById('movingError').textContent = '';
      hideResults();
      return;
    }
    var joinId = joinSel.value;
    var leaveId = leaveSel.value;
    document.getElementById('movingError').textContent = '';
    var seq = ++checklistReqSeq;
    if (btnRefresh) {
      btnRefresh.disabled = true;
      btnRefresh.classList.add('is-loading');
      btnRefresh.setAttribute('aria-busy', 'true');
    }
    loadConfig(joinId)
      .then(function (cfg) {
        if (seq !== checklistReqSeq) return;
        render(cfg, joinId, leaveId);
      })
      .catch(function (err) {
        if (seq !== checklistReqSeq) return;
        document.getElementById('movingError').textContent = err.message || String(err);
        document.getElementById('movingResults').hidden = true;
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

  function applyQueryParams() {
    var p = new URLSearchParams(window.location.search);
    var j = p.get('join');
    var l = p.get('leave');
    if (j && /^[a-z0-9-]+$/i.test(j) && joinSel.querySelector('option[value="' + j + '"]')) joinSel.value = j;
    if (l && /^[a-z0-9-]+$/i.test(l) && leaveSel.querySelector('option[value="' + l + '"]')) leaveSel.value = l;
    var planner = document.getElementById('moving-planner');
    if (planner && window.location.hash === '#moving-planner') {
      planner.scrollIntoView({ behavior: 'smooth' });
    }
  }

  fillSelect(joinSel, JOIN_OPTIONS);
  fillSelect(leaveSel, LEAVE_OPTIONS);
  applyQueryParams();

  joinSel.addEventListener('change', run);
  leaveSel.addEventListener('change', run);
  if (btnRefresh) btnRefresh.addEventListener('click', run);
  window.addEventListener('nhs-wallet-updated', run);
  window.addEventListener('nhs-auth-changed', run);

  run();
})();
