(function () {
  var HR_PAGE = typeof window.__HR_PAGE__ === 'string' ? window.__HR_PAGE__ : 'inbox';

  function batchViz() {
    return window.NHSBatchResultViz;
  }

      function wireHamburgerMenu() {
        var btn = document.getElementById('btnMenu');
        var panel = document.getElementById('menuPanel');
        if (!btn || !panel) return;
        function close() { panel.hidden = true; btn.setAttribute('aria-expanded', 'false'); }
        function open() { panel.hidden = false; btn.setAttribute('aria-expanded', 'true'); }
        btn.addEventListener('click', function (e) {
          e.preventDefault();
          if (panel.hidden) open(); else close();
        });
        document.addEventListener('click', function (e) {
          if (panel.hidden) return;
          if (btn.contains(e.target) || panel.contains(e.target)) return;
          close();
        }, true);
        document.addEventListener('keydown', function (e) { if (e.key === 'Escape') close(); });
      }

      function qs() { return new URLSearchParams(window.location.search); }
      function show(el, on) { if (el) el.hidden = !on; }
      function esc(s) { var d = document.createElement('div'); d.textContent = s || ''; return d.innerHTML; }

      function formatSharedAt(iso) {
        if (!iso) return '—';
        var d = new Date(iso);
        if (isNaN(d.getTime())) return String(iso).slice(0, 16).replace('T', ' ');
        return d.toLocaleString('en-GB', { day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' });
      }

      function doctorCellHtml(s) {
        var name = (s.doctor_name || s.doctor_email || '—').trim();
        var bits = ['<div class="hr-doctor-name">' + esc(name) + '</div>'];
        if (s.doctor_gmc) bits.push('<div class="hr-doctor-meta"><span>GMC</span> ' + esc(String(s.doctor_gmc)) + '</div>');
        if (s.doctor_trust) bits.push('<div class="hr-doctor-meta">' + esc(String(s.doctor_trust)) + '</div>');
        if (s.doctor_email && s.doctor_name) bits.push('<div class="hr-doctor-meta">' + esc(String(s.doctor_email)) + '</div>');
        return bits.join('');
      }

      function statusPillsHtml(s) {
        var v = s.verified_count || 0;
        var p = s.pending_count || 0;
        var dec = s.declined_count || 0;
        var parts = [];
        if (p > 0) parts.push('<span class="hr-count-pill hr-count-pill--pending">' + String(p) + ' pending</span>');
        if (v > 0) parts.push('<span class="hr-count-pill hr-count-pill--verified">' + String(v) + ' verified</span>');
        if (dec > 0) parts.push('<span class="hr-count-pill hr-count-pill--declined">' + String(dec) + ' declined</span>');
        if (!parts.length) parts.push('<span class="hr-count-pill">No records</span>');
        return '<div class="hr-count-row">' + parts.join('') + '</div>';
      }

      /** Merge inbox rows that belong to the same clinician (multiple share sessions). */
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
        return Object.keys(m).map(function (key) {
          var g = m[key];
          var sess = g.sessions;
          var pending = sess.reduce(function (a, x) { return a + (x.pending_count || 0); }, 0);
          var verified = sess.reduce(function (a, x) { return a + (x.verified_count || 0); }, 0);
          var declined = sess.reduce(function (a, x) { return a + (x.declined_count || 0); }, 0);
          var latest = sess.map(function (x) { return x.created_at; }).sort().slice(-1)[0];
          return {
            doctor_user_id: g.doctor_user_id,
            doctor_email: g.doctor_email,
            doctor_name: g.doctor_name,
            doctor_gmc: g.doctor_gmc,
            doctor_trust: g.doctor_trust,
            pending_count: pending,
            verified_count: verified,
            declined_count: declined,
            created_at: latest,
            _session_count: sess.length,
            sessions: sess,
          };
        }).sort(function (a, b) {
          return String(b.created_at || '').localeCompare(String(a.created_at || ''));
        });
      }

      async function apiJson(url, opts) {
        opts = opts || {};
        opts.credentials = 'include';
        var res = await fetch(url, opts);
        var text = await res.text();
        var data = null;
        try { data = text ? JSON.parse(text) : null; } catch (e) { data = null; }
        if (!res.ok) {
          var d = data && data.detail;
          throw new Error(typeof d === 'string' ? d : (text || res.statusText));
        }
        return data;
      }

      var hrIssuingDefaultsCache = null;
      async function fetchHrIssuingDefaults() {
        if (hrIssuingDefaultsCache) return hrIssuingDefaultsCache;
        try {
          hrIssuingDefaultsCache = await apiJson('/api/hr/issuing-defaults');
        } catch (e) {
          hrIssuingDefaultsCache = {
            profile_trust: '',
            issuing_trust_ods_code: '',
            issuing_trust_name: '',
            matched_trust_config: false,
          };
        }
        return hrIssuingDefaultsCache;
      }
      function setInputIfEmpty(id, val) {
        var el = document.getElementById(id);
        if (!el || val == null || String(val).trim() === '') return;
        if (String(el.value || '').trim() !== '') return;
        el.value = String(val);
      }

      var hrTrustSuggestSyncFns = [];
      function syncHrTrustSuggestLastAutoFromDom() {
        hrTrustSuggestSyncFns.forEach(function (fn) {
          try {
            fn();
          } catch (e) {}
        });
      }

      var hrTrustAutocompleteInited = false;
      function wireHrIssuingTrustAutocomplete(opts) {
        var nameId = opts.nameId;
        var odsId = opts.odsId;
        var listId = opts.listId;
        var wrapId = opts.wrapId;
        var nameEl = document.getElementById(nameId);
        var odsEl = document.getElementById(odsId);
        var listEl = document.getElementById(listId);
        var wrapEl = document.getElementById(wrapId);
        if (!nameEl || !odsEl || !listEl || !wrapEl || !window.NHSOdsTrustSuggest) return;

        var items = [];
        var active = -1;
        var debSuggest = null;
        var debOds = null;
        var lastAuto = { name: '', ods: '' };

        hrTrustSuggestSyncFns.push(function () {
          lastAuto.name = String(nameEl.value || '').trim();
          lastAuto.ods = String(odsEl.value || '').trim();
        });

        function hideList() {
          listEl.innerHTML = '';
          listEl.hidden = true;
          active = -1;
          items = [];
          nameEl.setAttribute('aria-expanded', 'false');
          nameEl.removeAttribute('aria-activedescendant');
        }

        function updateHighlight() {
          var lis = listEl.querySelectorAll('li[role="option"]');
          for (var j = 0; j < lis.length; j++) {
            lis[j].setAttribute('aria-selected', j === active ? 'true' : 'false');
          }
          if (active >= 0 && lis[active]) {
            nameEl.setAttribute('aria-activedescendant', lis[active].id);
            try {
              lis[active].scrollIntoView({ block: 'nearest' });
            } catch (eSc) {}
          } else {
            nameEl.removeAttribute('aria-activedescendant');
          }
        }

        function applyIndex(idx) {
          if (idx < 0 || idx >= items.length) return;
          var it = items[idx];
          nameEl.value = it.name || nameEl.value;
          if (it.ods) {
            var curOds = String(odsEl.value || '').trim();
            var shouldReplace = !curOds || curOds === lastAuto.ods;
            if (shouldReplace) odsEl.value = it.ods;
            lastAuto.name = String(nameEl.value || '').trim();
            lastAuto.ods = it.ods;
          }
          hideList();
        }

        function renderList(rows) {
          items = rows || [];
          listEl.innerHTML = '';
          active = -1;
          if (!items.length) {
            hideList();
            return;
          }
          for (var i = 0; i < items.length; i++) {
            var it = items[i];
            var li = document.createElement('li');
            li.setAttribute('role', 'option');
            li.id = listId + '-opt-' + i;
            li.dataset.index = String(i);
            var nameSpan = document.createElement('span');
            nameSpan.textContent = it.name;
            li.appendChild(nameSpan);
            if (it.ods) {
              var meta = document.createElement('span');
              meta.className = 'nhs-suggest-meta';
              meta.textContent = 'ODS ' + it.ods;
              li.appendChild(meta);
            }
            listEl.appendChild(li);
          }
          listEl.hidden = false;
          nameEl.setAttribute('aria-expanded', 'true');
        }

        async function runSuggest() {
          var q = String(nameEl.value || '').trim();
          if (q.length < 2) {
            hideList();
            return;
          }
          try {
            var res = await NHSOdsTrustSuggest.search(q, { minLength: 2, limit: 8 });
            renderList(res);
          } catch (e) {
            hideList();
          }
        }

        async function runPickBestOds() {
          var t = nameEl.value.trim();
          if (t.length < 3) return;
          var curOds = odsEl.value.trim();
          if (curOds && curOds !== lastAuto.ods) return;
          try {
            var org = await NHSOdsTrustSuggest.pickBestOrg(t, { minLength: 3 });
            if (!org || !org.OrgId) return;
            lastAuto.name = t;
            lastAuto.ods = org.OrgId;
            odsEl.value = org.OrgId;
          } catch (e2) {}
        }

        nameEl.addEventListener('input', function () {
          if (!String(nameEl.value || '').trim()) {
            lastAuto.name = '';
            lastAuto.ods = '';
          }
          if (debSuggest) clearTimeout(debSuggest);
          debSuggest = setTimeout(function () {
            debSuggest = null;
            void runSuggest();
          }, 320);
          if (debOds) clearTimeout(debOds);
          debOds = setTimeout(function () {
            debOds = null;
            void runPickBestOds();
          }, 480);
        });
        nameEl.addEventListener('change', function () {
          void runPickBestOds();
        });
        odsEl.addEventListener('input', function () {
          var v = String(odsEl.value || '').trim();
          if (!v) {
            lastAuto.name = '';
            lastAuto.ods = '';
          } else if (v !== lastAuto.ods) {
            lastAuto.name = '';
            lastAuto.ods = '';
          }
        });
        listEl.addEventListener('mousedown', function (ev) {
          if (ev.target.closest('li[role="option"]')) ev.preventDefault();
        });
        listEl.addEventListener('click', function (ev) {
          var li = ev.target.closest('li[role="option"]');
          if (!li) return;
          applyIndex(parseInt(li.dataset.index, 10));
        });
        nameEl.addEventListener('keydown', function (e) {
          if (listEl.hidden || !items.length) return;
          if (e.key === 'Escape') {
            e.preventDefault();
            hideList();
            return;
          }
          if (e.key === 'ArrowDown') {
            e.preventDefault();
            active = Math.min(active + 1, items.length - 1);
            if (active < 0) active = 0;
            updateHighlight();
          } else if (e.key === 'ArrowUp') {
            e.preventDefault();
            active = Math.max(active - 1, 0);
            updateHighlight();
          } else if (e.key === 'Enter' && active >= 0) {
            e.preventDefault();
            applyIndex(active);
          }
        });
        nameEl.addEventListener('blur', function () {
          window.setTimeout(hideList, 200);
        });
        document.addEventListener(
          'click',
          function (e) {
            if (!wrapEl.contains(e.target)) hideList();
          },
          true
        );
      }

      function initHrIssuingTrustAutocomplete() {
        if (hrTrustAutocompleteInited) return;
        hrTrustAutocompleteInited = true;
        wireHrIssuingTrustAutocomplete({
          nameId: 'bulkIssuingName',
          odsId: 'bulkOds',
          listId: 'hrBulkTrustSuggestList',
          wrapId: 'hrBulkTrustAcWrap',
        });
        wireHrIssuingTrustAutocomplete({
          nameId: 'addTrainingIssuingName',
          odsId: 'addTrainingOds',
          listId: 'hrAddTrainingTrustSuggestList',
          wrapId: 'hrAddTrainingTrustAcWrap',
        });
      }

      async function fillHrIssuingOdsFromOrdIfBlank(nameId, odsId) {
        var nameEl = document.getElementById(nameId);
        var odsEl = document.getElementById(odsId);
        if (!nameEl || !odsEl || !window.NHSOdsTrustSuggest) return;
        var nm = String(nameEl.value || '').trim();
        if (nm.length < 3 || String(odsEl.value || '').trim()) return;
        try {
          var org = await NHSOdsTrustSuggest.pickBestOrg(nm, { minLength: 3 });
          if (org && org.OrgId) odsEl.value = String(org.OrgId).trim().toUpperCase();
        } catch (e) {}
      }

      async function fillHrIssuingTrustFieldsIfEmpty() {
        var d = await fetchHrIssuingDefaults();
        setInputIfEmpty('bulkIssuingName', d.issuing_trust_name);
        setInputIfEmpty('bulkOds', d.issuing_trust_ods_code);
        setInputIfEmpty('addTrainingIssuingName', d.issuing_trust_name);
        setInputIfEmpty('addTrainingOds', d.issuing_trust_ods_code);
        await fillHrIssuingOdsFromOrdIfBlank('bulkIssuingName', 'bulkOds');
        await fillHrIssuingOdsFromOrdIfBlank('addTrainingIssuingName', 'addTrainingOds');
        syncHrTrustSuggestLastAutoFromDom();
      }

      var inboxTab = 'new';
      var itemsTab = 'new';
      var lastSessionPayload = null;

      function closeHrCertModal() {
        var modal = document.getElementById('hrCertModal');
        var body = document.getElementById('hrCertModalBody');
        if (body) body.innerHTML = '';
        if (modal) modal.hidden = true;
      }

      function closeHrAddTrainingModal() {
        var m = document.getElementById('hrAddTrainingModal');
        if (m) m.hidden = true;
      }

      function openHrCertModal(it) {
        var modal = document.getElementById('hrCertModal');
        var title = document.getElementById('hrCertModalTitle');
        var body = document.getElementById('hrCertModalBody');
        if (!modal || !body || !it || !it.certificate_base64) return;
        var name = (it.module_name || it.credential_id || 'Evidence').trim();
        if (title) title.textContent = name;
        var fn = String(it.certificate_filename || 'evidence').toLowerCase();
        var ext = (fn.split('.').pop() || '').toLowerCase();
        var mime = ext === 'pdf' ? 'application/pdf' : (ext === 'png' ? 'image/png' : (ext === 'webp' ? 'image/webp' : 'image/jpeg'));
        var b64 = String(it.certificate_base64).replace(/\s/g, '');
        if (mime === 'application/pdf') {
          body.innerHTML = '<iframe class="hr-cert-iframe" title="Uploaded evidence" src="data:' + mime + ';base64,' + b64 + '"></iframe>';
        } else {
          body.innerHTML = '<img class="hr-cert-img" alt="Uploaded evidence" src="data:' + mime + ';base64,' + b64 + '" />';
        }
        modal.hidden = false;
      }

      function wireTabs(containerId, onPick) {
        var root = document.getElementById(containerId);
        if (!root) return;
        root.addEventListener('click', function (e) {
          var b = e.target && e.target.closest('button[data-tab]');
          if (!b) return;
          e.preventDefault();
          var wanted = b.getAttribute('data-tab');
          Array.from(root.querySelectorAll('button[data-tab]')).forEach(function (x) {
            var active = x === b;
            x.classList.toggle('active', active);
            x.setAttribute('aria-selected', active ? 'true' : 'false');
          });
          onPick(wanted);
        });
      }

      async function loadInbox() {
        var tbody = document.getElementById('sessionsTbody');
        var summaryEl = document.getElementById('inboxSummary');
        tbody.innerHTML = '<tr><td colspan="4" class="hr-muted">Loading…</td></tr>';
        if (summaryEl) summaryEl.textContent = '';
        var data = await apiJson('/api/hr/shares?limit=200');
        var all = (data.sessions || []);
        var sessions = all.filter(function (s) {
          var sk = String(s.share_kind || 'review').toLowerCase();
          var isPortfolio = sk === 'portfolio';
          var hasPending = (s.pending_count || 0) > 0;
          if (inboxTab === 'new') return !isPortfolio && hasPending;
          return !isPortfolio && !hasPending;
        });
        var groups = aggregateDoctorGroups(sessions);
        if (summaryEl) {
          if (inboxTab === 'new') {
            if (groups.length === 0) {
              summaryEl.innerHTML = 'Nothing waiting — <strong>all caught up</strong> for now.';
            } else if (groups.length === 1) {
              summaryEl.innerHTML = '<strong>1</strong> clinician still has records to verify.';
            } else {
              summaryEl.innerHTML = '<strong>' + String(groups.length) + '</strong> clinicians still have records to verify.';
            }
          } else {
            summaryEl.innerHTML = groups.length === 0
              ? 'No completed sets in this list yet.'
              : '<strong>' + String(groups.length) + '</strong> clinician(s) with every submission fully verified or declined.';
          }
        }
        var rows = groups.map(function (g) {
          var when = formatSharedAt(g.created_at);
          var sub = '';
          if ((g._session_count || 0) > 1) {
            sub = '<div class="hr-date-sub">' + String(g._session_count) + ' submissions · latest below</div>';
          }
          var reviewHref =
            g.doctor_user_id != null && g.doctor_user_id !== ''
              ? '/static/hr/?doctor=' + encodeURIComponent(String(g.doctor_user_id))
              : '/static/hr/?session=' + encodeURIComponent(String((g.sessions && g.sessions[0] && g.sessions[0].session_id) || ''));
          return (
            '<tr>' +
              '<td>' + doctorCellHtml(g) + '</td>' +
              '<td><div class="hr-date-main">' + esc(when) + '</div>' + sub + '</td>' +
              '<td>' + statusPillsHtml(g) + '</td>' +
              '<td class="hr-open-wrap"><a class="hr-open-btn" href="' + reviewHref + '">Review</a></td>' +
            '</tr>'
          );
        }).join('');
        tbody.innerHTML =
          rows ||
          '<tr><td colspan="4" class="hr-muted">' +
            (inboxTab === 'new' ? 'No sets need action right now.' : 'No completed sets to show.') +
            '</td></tr>';
      }

      /**
       * @param fixedSessionId When set, single-session review (/api/hr/shares/:id). When null, merged doctor queue (each item carries session_id).
       */
      function renderItemsTable(payload, fixedSessionId) {
        var tbody = document.getElementById('itemsTbody');
        var s = payload;
        var merged = fixedSessionId == null || fixedSessionId === '';
        var fallbackAnyCert = '';
        var fallbackAnyFilename = '';
        var fallbackAnyItem = (s.items || []).find(function (x) {
          return x && x.certificate_base64 && String(x.certificate_base64).trim();
        });
        if (fallbackAnyItem) {
          fallbackAnyCert = String(fallbackAnyItem.certificate_base64 || '').trim();
          fallbackAnyFilename = String(fallbackAnyItem.certificate_filename || 'evidence');
        }
        var portfolioSession = String(s.share_kind || '').toLowerCase() === 'portfolio';
        var anyPortfolioMerged = false;
        if (merged) {
          (s.items || []).forEach(function (it) {
            if (String(it.session_share_kind || '').toLowerCase() === 'portfolio') anyPortfolioMerged = true;
          });
        }
        var showPortfolioBanner = portfolioSession || (merged && anyPortfolioMerged);
        var metaBlock = document.getElementById('sessionMetaBlock');
        if (metaBlock) {
          var name = (s.doctor_name || s.doctor_email || '—').trim();
          var sub = [];
          if (s.doctor_gmc) sub.push('<span><span>GMC</span> ' + esc(String(s.doctor_gmc)) + '</span>');
          if (s.doctor_trust) sub.push('<span>' + esc(String(s.doctor_trust)) + '</span>');
          if (s.doctor_email && s.doctor_name) sub.push('<span>' + esc(String(s.doctor_email)) + '</span>');
          var tail = '';
          if (showPortfolioBanner) {
            tail +=
              '<div class="hr-muted" style="text-align:right; max-width:24rem; margin:0.5rem 0 0 auto; font-size:0.875rem; line-height:1.45;">' +
              '<strong>Reference pack</strong> — already verified by HR at the clinician&rsquo;s other employer. View-only here; no verify or decline.</div>';
          }
          if (merged && (s.session_ids || []).length > 1) {
            tail += '<div class="hr-date-sub" style="text-align:right;">' + String(s.session_ids.length) + ' submissions combined</div>';
          } else if (!merged && s.created_at) {
            tail += '<div class="hr-date-sub" style="text-align:right;">Shared ' + esc(formatSharedAt(s.created_at)) + '</div>';
          }
          metaBlock.innerHTML =
            '<div class="hr-doctor-name" style="text-align:right;">' + esc(name) + '</div>' +
            (sub.length ? '<div class="hr-doctor-meta" style="text-align:right;">' + sub.join(' · ') + '</div>' : '') +
            tail;
        }
        var items = (s.items || []).filter(function (it) {
          var st = String(it.status || '').toUpperCase();
          var pending = st !== 'VERIFIED' && st !== 'DECLINED';
          var pr = merged
            ? String(it.session_share_kind || '').toLowerCase() === 'portfolio'
            : portfolioSession;
          if (pr) return itemsTab === 'new';
          return itemsTab === 'new' ? pending : !pending;
        });
        var prevSid = null;
        var parts = [];
        items.forEach(function (it) {
          if (merged && (s.session_ids || []).length > 1 && it.session_id != null && it.session_id !== prevSid) {
            prevSid = it.session_id;
            var when = formatSharedAt(it.session_created_at);
            parts.push(
              '<tr class="hr-session-divider"><td colspan="4">Submission · ' +
                esc(when) +
                ' · #' +
                esc(String(it.session_id)) +
                '</td></tr>'
            );
          }
          var st = String(it.status || '').toUpperCase();
          var portfolioRow = merged
            ? String(it.session_share_kind || '').toLowerCase() === 'portfolio'
            : portfolioSession;
          var pill =
            st === 'VERIFIED'
              ? '<span class="hr-pill hr-pill--verified">VERIFIED</span>'
              : st === 'DECLINED'
                ? '<span class="hr-pill">DECLINED</span>'
                : '<span class="hr-pill">PENDING</span>';
          var isArchived = st === 'VERIFIED' || st === 'DECLINED';
          var sidForApi =
            merged && it.session_id != null ? String(it.session_id) : fixedSessionId != null ? String(fixedSessionId) : '';
          var btn =
            isArchived || portfolioRow
              ? '<span class="hr-muted">—</span>'
              : '<div class="hr-actions">' +
                '<button type="button" class="nhsuk-button hr-btn-small" data-verify="1" data-sid="' +
                esc(sidForApi) +
                '" data-cid="' +
                esc(it.credential_id) +
                '">Verify</button>' +
                '<button type="button" class="nhsuk-button nhsuk-button--secondary hr-btn-small" data-decline="1" data-sid="' +
                esc(sidForApi) +
                '" data-cid="' +
                esc(it.credential_id) +
                '">Decline</button>' +
                '</div>';
          var note =
            st === 'DECLINED' && it.decline_reason
              ? '<div class="hr-muted" style="margin-top:0.25rem;">Reason: ' + esc(it.decline_reason) + '</div>'
              : '';
          var priorNote =
            portfolioRow && it.decision_at
              ? '<div class="hr-muted" style="margin-top:0.25rem;">HR verified elsewhere · ' +
                esc(formatSharedAt(it.decision_at)) +
                '</div>'
              : '';
          var issuingLine = it.issuing_trust_name
            ? '<div class="hr-muted" style="margin-top:0.25rem;">Issuing organisation: ' +
              esc(String(it.issuing_trust_name)) +
              '</div>'
            : '';
          var verifierTrustLine = it.verified_by_trust_name
            ? '<div class="hr-muted" style="margin-top:0.25rem;">HR verified at: ' +
              esc(String(it.verified_by_trust_name)) +
              '</div>'
            : '';
          var rowCert = (it.certificate_base64 && String(it.certificate_base64).trim()) ? String(it.certificate_base64).trim() : '';
          var fallbackSameSubmissionCert = '';
          if (!rowCert && it.session_id != null) {
            var fallbackItem = (s.items || []).find(function (x) {
              return String(x.session_id) === String(it.session_id) &&
                x.certificate_base64 &&
                String(x.certificate_base64).trim();
            });
            if (fallbackItem && fallbackItem.certificate_base64) {
              fallbackSameSubmissionCert = String(fallbackItem.certificate_base64).trim();
            }
          }
          var hasCert = !!(rowCert || fallbackSameSubmissionCert || fallbackAnyCert);
          var modLabel = esc(it.module_name || it.credential_id || '—');
          var modCell = hasCert
            ? '<button type="button" class="hr-module-name-btn" data-view-cert="1" data-cid="' +
              esc(it.credential_id) +
              '" data-sid="' +
              esc(sidForApi) +
              '" data-fallback-any="' +
              esc(fallbackAnyCert) +
              '" data-fallback-fn="' +
              esc(fallbackAnyFilename) +
              '" title="View evidence uploaded with this record">' +
              modLabel +
              '</button>'
            : modLabel;
          parts.push(
            '<tr>' +
              '<td>' +
              modCell +
              priorNote +
              issuingLine +
              verifierTrustLine +
              note +
              '</td>' +
              '<td>' +
              esc(it.expiry_date || '—') +
              '</td>' +
              '<td>' +
              pill +
              '</td>' +
              '<td>' +
              btn +
              '</td>' +
              '</tr>'
          );
        });
        tbody.innerHTML = parts.join('') || '<tr><td colspan="4" class="hr-muted">No items.</td></tr>';
      }

      async function loadDoctorQueue(doctorUserId) {
        var tbody = document.getElementById('itemsTbody');
        var titleEl = document.getElementById('sessionViewTitle');
        if (titleEl) titleEl.textContent = 'E-learning from this clinician';
        tbody.innerHTML = '<tr><td colspan="4" class="hr-muted">Loading…</td></tr>';
        lastSessionPayload = await apiJson('/api/hr/doctors/' + encodeURIComponent(String(doctorUserId)) + '/queue');
        renderItemsTable(lastSessionPayload, null);
        attachItemsRowHandler(null);
      }

      function attachItemsRowHandler(fixedSessionId) {
        var tbody = document.getElementById('itemsTbody');
        var actionInFlight = false;
        tbody.onclick = async function (e) {
          var viewCert = e.target && e.target.closest('button[data-view-cert="1"]');
          if (viewCert) {
            e.preventDefault();
            var cid = viewCert.getAttribute('data-cid');
            var sid = viewCert.getAttribute('data-sid');
            var it = (lastSessionPayload.items || []).find(function (x) {
              return String(x.credential_id) === String(cid);
            });
            if ((!it || !it.certificate_base64) && sid) {
              var fallback = (lastSessionPayload.items || []).find(function (x) {
                return String(x.session_id) === String(sid) &&
                  x.certificate_base64 &&
                  String(x.certificate_base64).trim();
              });
              if (fallback) it = fallback;
            }
            if ((!it || !it.certificate_base64) && viewCert.getAttribute('data-fallback-any')) {
              it = {
                module_name: (it && it.module_name) || 'Evidence',
                certificate_base64: viewCert.getAttribute('data-fallback-any'),
                certificate_filename: viewCert.getAttribute('data-fallback-fn') || 'evidence',
              };
            }
            if (it && it.certificate_base64) openHrCertModal(it);
            return;
          }
          if (actionInFlight) return;
          var v = e.target && e.target.closest('button[data-verify="1"]');
          var d = e.target && e.target.closest('button[data-decline="1"]');
          if (!v && !d) return;
          var cid2 = (v || d).getAttribute('data-cid');
          var sidAttr = (v || d).getAttribute('data-sid');
          var sessionIdForApi = sidAttr || (fixedSessionId != null ? String(fixedSessionId) : '');
          if (!sessionIdForApi) {
            alert('Missing session for this action.');
            return;
          }
          actionInFlight = true;
          try {
            if (v) {
              v.disabled = true;
              v.textContent = 'Verifying…';
              await apiJson(
                '/api/hr/shares/' +
                  encodeURIComponent(sessionIdForApi) +
                  '/items/' +
                  encodeURIComponent(String(cid2)) +
                  '/verify',
                { method: 'POST' }
              );
            } else {
              var reason = (
                prompt('Why are you declining this record? (This will be sent back to the doctor)') || ''
              ).trim();
              if (!reason) {
                actionInFlight = false;
                return;
              }
              d.disabled = true;
              d.textContent = 'Declining…';
              await apiJson(
                '/api/hr/shares/' +
                  encodeURIComponent(sessionIdForApi) +
                  '/items/' +
                  encodeURIComponent(String(cid2)) +
                  '/decline',
                {
                  method: 'POST',
                  headers: { 'Content-Type': 'application/json' },
                  body: JSON.stringify({ reason: reason }),
                }
              );
            }
            await refreshPayloadAfterAction(fixedSessionId);
            if (window.NHSNavAccount && typeof NHSNavAccount.notifyVerifyInboxChanged === 'function') {
              NHSNavAccount.notifyVerifyInboxChanged();
            }
          } catch (err) {
            alert(err.message || err);
            await refreshPayloadAfterAction(fixedSessionId);
          } finally {
            actionInFlight = false;
          }
        };
      }

      async function refreshPayloadAfterAction(fixedSessionId) {
        if (fixedSessionId != null && fixedSessionId !== '') {
          lastSessionPayload = await apiJson('/api/hr/shares/' + encodeURIComponent(String(fixedSessionId)));
          renderItemsTable(lastSessionPayload, fixedSessionId);
          return;
        }
        var uid = lastSessionPayload && lastSessionPayload.doctor_user_id;
        if (uid != null) {
          lastSessionPayload = await apiJson('/api/hr/doctors/' + encodeURIComponent(String(uid)) + '/queue');
          renderItemsTable(lastSessionPayload, null);
        }
      }

      async function loadSession(sessionId) {
        var tbody = document.getElementById('itemsTbody');
        var titleEl = document.getElementById('sessionViewTitle');
        if (titleEl) titleEl.textContent = 'E-learning in this set';
        tbody.innerHTML = '<tr><td colspan="4" class="hr-muted">Loading…</td></tr>';
        lastSessionPayload = await apiJson('/api/hr/shares/' + encodeURIComponent(String(sessionId)));
        if (titleEl) {
          titleEl.textContent =
            String(lastSessionPayload.share_kind || '').toLowerCase() === 'portfolio'
              ? 'Reference pack (verified elsewhere)'
              : 'E-learning in this set';
        }
        renderItemsTable(lastSessionPayload, sessionId);
        attachItemsRowHandler(sessionId);
      }

      (async function boot() {
        await NHSAuth.refresh();
        if (!NHSAuth.requireAuth()) return;
        if (window.NHSNavAccount) void NHSNavAccount.refresh();
        wireHamburgerMenu();

        document.getElementById('btnSignOut').addEventListener('click', async function () {
          await NHSAuth.signOut();
          window.location.replace('/');
        });
        var btnBackEl = document.getElementById('btnBack');
        if (btnBackEl) {
          btnBackEl.addEventListener('click', function () {
            window.location.assign('/static/hr/');
          });
        }
        var hrCertClose = document.getElementById('hrCertModalClose');
        if (hrCertClose) hrCertClose.addEventListener('click', closeHrCertModal);
        var hrCertModal = document.getElementById('hrCertModal');
        if (hrCertModal) {
          hrCertModal.addEventListener('click', function (e) {
            if (e.target === hrCertModal) closeHrCertModal();
          });
        }
        var hrAddTrainingModal = document.getElementById('hrAddTrainingModal');
        if (hrAddTrainingModal) {
          hrAddTrainingModal.addEventListener('click', function (e) {
            if (e.target === hrAddTrainingModal) closeHrAddTrainingModal();
          });
        }
        var addTrainingCancel = document.getElementById('addTrainingCancel');
        if (addTrainingCancel) addTrainingCancel.addEventListener('click', closeHrAddTrainingModal);
        document.addEventListener('keydown', function (e) {
          if (e.key === 'Escape') {
            closeHrCertModal();
            closeHrAddTrainingModal();
          }
        });

        if (!NHSAuth.user.premium) {
          show(document.getElementById('notPremium'), true);
          show(document.getElementById('inboxView'), false);
          show(document.getElementById('sessionView'), false);
          if (HR_PAGE === 'search') {
            show(document.getElementById('searchView'), false);
            show(document.getElementById('searchDoctorView'), false);
          }
          if (HR_PAGE === 'bulk') {
            show(document.getElementById('bulkView'), false);
          }
          return;
        }

        var addTrainingDoctorId = '';

        var BULK_MODULES = [
          { code: 'fire_safety', name: 'Fire Safety' },
          { code: 'infection_control', name: 'Infection Prevention and Control' },
          { code: 'information_governance', name: 'Information Governance' },
          { code: 'moving_handling', name: 'Moving and Handling' },
          { code: 'resuscitation', name: 'Resuscitation Awareness' },
          { code: 'conflict_resolution', name: 'Conflict Resolution' },
          { code: 'safeguarding_level_1', name: 'Safeguarding Adults and Children Level 1' },
          { code: 'safeguarding_level_2', name: 'Safeguarding Adults and Children Level 2' },
          { code: 'safeguarding_level_3', name: 'Safeguarding Adults and Children Level 3' },
          { code: 'non_cstf', name: 'Non-CSTF competency (ESR / local)' },
        ];

        function fillHrModuleSelect(sel) {
          if (!sel) return;
          if (sel.options && sel.options.length > 0) return;
          BULK_MODULES.forEach(function (m) {
            var o = document.createElement('option');
            o.value = m.code;
            o.textContent = m.name;
            sel.appendChild(o);
          });
        }

        function setAddTrainingStatus(msg, kind) {
          var el = document.getElementById('addTrainingStatus');
          if (!el) return;
          el.hidden = false;
          el.textContent = msg || '';
          el.className = 'hr-bulk-status--muted';
          if (kind === 'error') el.className = 'hr-bulk-status--error';
          else if (kind === 'ok') el.className = 'hr-bulk-status--ok';
          else el.classList.add('hr-muted');
        }

        function openHrAddTrainingModal(doctorId, doctorName) {
          var m = document.getElementById('hrAddTrainingModal');
          var t = document.getElementById('hrAddTrainingTitle');
          var form = document.getElementById('addTrainingForm');
          if (!m || !form) return;
          addTrainingDoctorId = String(doctorId || '');
          var dname = doctorName || '';
          if (t) t.textContent = 'Add training — ' + (dname || 'Clinician');
          form.reset();
          var nm = document.getElementById('addTrainingEvidenceName');
          if (nm) nm.textContent = '';
          if (batchViz()) batchViz().clear(document.getElementById('addTrainingProvisionResult'));
          var addStEl = document.getElementById('addTrainingStatus');
          if (addStEl) {
            addStEl.hidden = true;
            addStEl.textContent = '';
          }
          void (async function () {
            await fillHrIssuingTrustFieldsIfEmpty();
            m.hidden = false;
          })();
        }

        var searchDoctorItemsCache = [];

        var bulkMod = document.getElementById('bulkModule');
        if (bulkMod) fillHrModuleSelect(bulkMod);

        var bulkWizardStep = 1;
        var bulkRecipientMethod = null;

        function setBulkStepError(elId, msg) {
          var el = document.getElementById(elId);
          if (!el) return;
          el.textContent = msg || '';
          el.hidden = !msg;
        }

        function syncBulkRosterPicker() {
          var inp = document.getElementById('bulkRoster');
          var picker = document.getElementById('bulkRosterPicker');
          var done = document.getElementById('bulkRosterDone');
          var has = inp && inp.files && inp.files[0];
          if (picker) picker.hidden = !!has;
          if (done) {
            if (has) {
              done.innerHTML = '<strong>Roster file selected.</strong> ' + esc(inp.files[0].name) + ' — continue to class evidence.';
              done.hidden = false;
            } else {
              done.hidden = true;
              done.textContent = '';
            }
          }
        }

        function syncBulkEvidencePicker() {
          var inp = document.getElementById('bulkEvidence');
          var picker = document.getElementById('bulkEvidencePicker');
          var done = document.getElementById('bulkEvidenceDone');
          var has = inp && inp.files && inp.files[0];
          if (picker) picker.hidden = !!has;
          if (done) {
            if (has) {
              done.innerHTML = '<strong>Evidence file selected.</strong> ' + esc(inp.files[0].name) + ' — continue to training details.';
              done.hidden = false;
            } else {
              done.hidden = true;
              done.textContent = '';
            }
          }
        }

        function updateBulkRecipientsSummary() {
          var el = document.getElementById('bulkRecipientsSummary');
          if (!el) return;
          if (bulkRecipientMethod === 'cohort') {
            var sel = document.getElementById('bulkCohort');
            var opt = sel && sel.options[sel.selectedIndex];
            el.textContent = opt && opt.value
              ? 'Recipients: cohort “' + (opt.textContent || '').trim() + '”.'
              : '';
          } else if (bulkRecipientMethod === 'roster') {
            var r = document.getElementById('bulkRoster');
            var name = r && r.files && r.files[0] ? r.files[0].name : '';
            el.textContent = name ? 'Recipients: roster file “' + name + '”.' : 'Recipients: roster file.';
          } else {
            el.textContent = '';
          }
        }

        function setBulkWizardStep(step) {
          bulkWizardStep = step;
          var label = document.getElementById('bulkWizardStepLabel');
          if (label) {
            if (step === 1) label.textContent = 'Step 1 of 4 — Who receives this?';
            else if (step === 2) {
              label.textContent = bulkRecipientMethod === 'cohort'
                ? 'Step 2 of 4 — Choose cohort'
                : 'Step 2 of 4 — Upload roster';
            } else if (step === 3) label.textContent = 'Step 3 of 4 — Class evidence';
            else label.textContent = 'Step 4 of 4 — Training details';
          }
          var stepMethod = document.getElementById('bulkStepMethod');
          var stepCohort = document.getElementById('bulkStepCohort');
          var stepRoster = document.getElementById('bulkStepRoster');
          var stepEvidence = document.getElementById('bulkStepEvidence');
          var stepDetails = document.getElementById('bulkStepDetails');
          if (stepMethod) stepMethod.hidden = step !== 1;
          if (stepCohort) stepCohort.hidden = !(step === 2 && bulkRecipientMethod === 'cohort');
          if (stepRoster) stepRoster.hidden = !(step === 2 && bulkRecipientMethod === 'roster');
          if (stepEvidence) stepEvidence.hidden = step !== 3;
          if (stepDetails) stepDetails.hidden = step !== 4;
          if (step === 2 && bulkRecipientMethod === 'roster') syncBulkRosterPicker();
          if (step === 3) syncBulkEvidencePicker();
          if (step === 4) updateBulkRecipientsSummary();
        }

        function resetBulkWizard() {
          bulkWizardStep = 1;
          bulkRecipientMethod = null;
          var cohortSel = document.getElementById('bulkCohort');
          if (cohortSel) cohortSel.value = '';
          var rosterEl = document.getElementById('bulkRoster');
          var evidenceEl = document.getElementById('bulkEvidence');
          if (rosterEl) rosterEl.value = '';
          if (evidenceEl) evidenceEl.value = '';
          var rn = document.getElementById('bulkRosterName');
          var en = document.getElementById('bulkEvidenceName');
          if (rn) rn.textContent = 'No file chosen';
          if (en) en.textContent = 'No file chosen';
          setBulkStepError('bulkStepCohortError', '');
          setBulkStepError('bulkStepRosterError', '');
          setBulkStepError('bulkStepEvidenceError', '');
          syncBulkRosterPicker();
          syncBulkEvidencePicker();
          setBulkWizardStep(1);
        }

        async function fillBulkCohortSelect() {
          var sel = document.getElementById('bulkCohort');
          if (!sel || HR_PAGE !== 'bulk') return;
          try {
            var data = await apiJson('/api/hr/cohorts');
            var cohorts = data.cohorts || [];
            sel.innerHTML = '<option value="">Choose a cohort…</option>';
            cohorts.forEach(function (c) {
              var opt = document.createElement('option');
              opt.value = String(c.id);
              var n = (c.name || 'Cohort').trim();
              var cnt = c.member_count != null ? c.member_count : 0;
              opt.textContent = n + ' (' + cnt + ' member' + (cnt === 1 ? '' : 's') + ')';
              sel.appendChild(opt);
            });
          } catch (e) {
            /* keep default option */
          }
        }

        if (HR_PAGE === 'bulk') {
          document.querySelectorAll('[data-bulk-method]').forEach(function (btn) {
            btn.addEventListener('click', function () {
              bulkRecipientMethod = btn.getAttribute('data-bulk-method');
              setBulkWizardStep(2);
              if (bulkRecipientMethod === 'cohort') {
                var sel = document.getElementById('bulkCohort');
                if (sel) sel.focus();
              } else {
                syncBulkRosterPicker();
                var r = document.getElementById('bulkRoster');
                if (r) r.focus();
              }
            });
          });

          var bulkNextCohort = document.getElementById('bulkNextCohort');
          if (bulkNextCohort) {
            bulkNextCohort.addEventListener('click', function () {
              var sel = document.getElementById('bulkCohort');
              if (!sel || !sel.value) {
                setBulkStepError('bulkStepCohortError', 'Choose a cohort to continue.');
                if (sel) sel.focus();
                return;
              }
              setBulkStepError('bulkStepCohortError', '');
              setBulkWizardStep(3);
              var ev = document.getElementById('bulkEvidence');
              if (ev) ev.focus();
            });
          }

          var bulkBackCohort = document.getElementById('bulkBackCohort');
          if (bulkBackCohort) bulkBackCohort.addEventListener('click', function () { setBulkWizardStep(1); });

          var bulkNextRoster = document.getElementById('bulkNextRoster');
          if (bulkNextRoster) {
            bulkNextRoster.addEventListener('click', function () {
              var rosterEl = document.getElementById('bulkRoster');
              if (!rosterEl || !rosterEl.files || !rosterEl.files[0]) {
                setBulkStepError('bulkStepRosterError', 'Choose a roster file to continue.');
                if (rosterEl) rosterEl.focus();
                return;
              }
              setBulkStepError('bulkStepRosterError', '');
              setBulkWizardStep(3);
              var ev = document.getElementById('bulkEvidence');
              if (ev) ev.focus();
            });
          }

          var bulkBackRoster = document.getElementById('bulkBackRoster');
          if (bulkBackRoster) bulkBackRoster.addEventListener('click', function () { setBulkWizardStep(1); });

          var bulkNextEvidence = document.getElementById('bulkNextEvidence');
          if (bulkNextEvidence) {
            bulkNextEvidence.addEventListener('click', function () {
              var evEl = document.getElementById('bulkEvidence');
              if (!evEl || !evEl.files || !evEl.files[0]) {
                setBulkStepError('bulkStepEvidenceError', 'Choose a class evidence file to continue.');
                if (evEl) evEl.focus();
                return;
              }
              setBulkStepError('bulkStepEvidenceError', '');
              setBulkWizardStep(4);
              var mod = document.getElementById('bulkModule');
              if (mod) mod.focus();
            });
          }

          var bulkBackEvidence = document.getElementById('bulkBackEvidence');
          if (bulkBackEvidence) {
            bulkBackEvidence.addEventListener('click', function () {
              setBulkWizardStep(bulkRecipientMethod === 'cohort' ? 2 : 2);
              if (bulkRecipientMethod === 'cohort') {
                var sel = document.getElementById('bulkCohort');
                if (sel) sel.focus();
              } else {
                syncBulkRosterPicker();
              }
            });
          }

          var bulkBackDetails = document.getElementById('bulkBackDetails');
          if (bulkBackDetails) {
            bulkBackDetails.addEventListener('click', function () {
              setBulkWizardStep(3);
              syncBulkEvidencePicker();
            });
          }

          void (async function () {
            await fillBulkCohortSelect();
            resetBulkWizard();
          })();
        }
        fillHrModuleSelect(document.getElementById('addTrainingModule'));
        initHrIssuingTrustAutocomplete();

        var sdTbody = document.getElementById('searchDoctorItemsTbody');
        if (sdTbody && !sdTbody.dataset.certWired) {
          sdTbody.dataset.certWired = '1';
          sdTbody.addEventListener('click', function (e) {
            var btn = e.target && e.target.closest('button[data-view-docs-cid]');
            if (!btn) return;
            var cid = btn.getAttribute('data-view-docs-cid');
            var it = searchDoctorItemsCache.find(function (x) { return String(x.credential_id) === String(cid); });
            if (it && it.certificate_base64) openHrCertModal(it);
          });
        }

        var searchResultsList = document.getElementById('searchResultsList');
        if (searchResultsList && !searchResultsList.dataset.rowWired) {
          searchResultsList.dataset.rowWired = '1';
          searchResultsList.addEventListener('click', async function (e) {
            var viewBtn = e.target && e.target.closest('button[data-search-doctor-id]');
            if (viewBtn) {
              var did = viewBtn.getAttribute('data-search-doctor-id');
              var dname = viewBtn.getAttribute('data-search-doctor-name') || 'Doctor';
              await openSearchDoctorView(did, dname);
              return;
            }
            var addBtn = e.target && e.target.closest('button[data-add-doctor-id]');
            if (addBtn) {
              e.preventDefault();
              openHrAddTrainingModal(
                addBtn.getAttribute('data-add-doctor-id'),
                addBtn.getAttribute('data-add-doctor-name') || ''
              );
            }
          });
        }

        var btnSearchDoctorAddTraining = document.getElementById('btnSearchDoctorAddTraining');
        if (btnSearchDoctorAddTraining) {
          btnSearchDoctorAddTraining.addEventListener('click', function () {
            var id = this.getAttribute('data-doctor-id');
            var name = this.getAttribute('data-doctor-name') || '';
            if (id) openHrAddTrainingModal(id, name);
          });
        }

        var addTrainingFormEl = document.getElementById('addTrainingForm');
        var addTrainingSubmitBtn = document.getElementById('addTrainingSubmit');
        var addTrainingBusy = false;
        if (addTrainingFormEl && addTrainingSubmitBtn) {
          addTrainingFormEl.addEventListener('submit', async function (e) {
            e.preventDefault();
            if (addTrainingBusy || !addTrainingDoctorId) return;
            var evEl = document.getElementById('addTrainingEvidence');
            var addMod = document.getElementById('addTrainingModule');
            if (!addTrainingFormEl.reportValidity()) return;
            if (!evEl || !evEl.files || !evEl.files[0]) {
              setAddTrainingStatus('Choose an evidence file.', 'error');
              return;
            }
            addTrainingBusy = true;
            addTrainingSubmitBtn.disabled = true;
            var addVizEl = document.getElementById('addTrainingProvisionResult');
            var addSt = document.getElementById('addTrainingStatus');
            if (addSt) addSt.hidden = true;
            if (batchViz()) batchViz().clear(addVizEl);
            if (batchViz()) batchViz().showLoading(addVizEl, 'Issuing training record…');
            try {
              var fd = new FormData();
              if (evEl && evEl.files && evEl.files[0]) fd.append('evidence', evEl.files[0]);
              fd.append('module_code', (addMod && addMod.value) ? addMod.value : 'fire_safety');
              fd.append('completion_date', (document.getElementById('addTrainingCompletion') || {}).value || '');
              fd.append('expiry_date', (document.getElementById('addTrainingExpiry') || {}).value || '');
              var ods = (document.getElementById('addTrainingOds') || {}).value;
              var iname = (document.getElementById('addTrainingIssuingName') || {}).value;
              if (ods && String(ods).trim()) fd.append('issuing_trust_ods_code', String(ods).trim());
              if (iname && String(iname).trim()) fd.append('issuing_trust_name', String(iname).trim());
              var url = '/api/hr/doctors/' + encodeURIComponent(addTrainingDoctorId) + '/add-training';
              var res = await fetch(url, { method: 'POST', body: fd, credentials: 'include' });
              var text = await res.text();
              var data = null;
              try { data = text ? JSON.parse(text) : null; } catch (e2) { data = null; }
              if (!res.ok) {
                var d = data && data.detail;
                throw new Error(typeof d === 'string' ? d : (text || res.statusText));
              }
              var errCount = Number(data.errors || 0);
              var issued = Number(data.issued || 0);
              if (batchViz()) {
                batchViz().singleTraining(addVizEl, data, {
                  followUpNote: issued
                    ? 'Close this dialog to return to the list; the table below refreshes automatically.'
                    : '',
                });
              } else if (addSt) {
                var row0 = (data.rows && data.rows[0]) || {};
                addSt.hidden = false;
                setAddTrainingStatus(row0.message || 'Done.', errCount > 0 ? 'error' : 'ok');
              }
              var sdv = document.getElementById('searchDoctorView');
              if (issued && sdv && !sdv.hidden) {
                var titleEl = document.getElementById('searchDoctorTitle');
                var dnm = '';
                if (titleEl) {
                  dnm = String(titleEl.textContent || '').replace(/^Verified training — /, '').trim();
                }
                await openSearchDoctorView(addTrainingDoctorId, dnm || 'Doctor');
              }
            } catch (err) {
              if (batchViz()) batchViz().clear(addVizEl);
              if (addSt) {
                addSt.hidden = false;
                setAddTrainingStatus(err.message || 'Request failed.', 'error');
              }
            } finally {
              addTrainingBusy = false;
              addTrainingSubmitBtn.disabled = false;
            }
          });
        }

        function wireBulkFileName(inputId, nameId, onChange, staffStyle) {
          var inp = document.getElementById(inputId);
          var nameEl = document.getElementById(nameId);
          if (!inp || !nameEl) return;
          inp.addEventListener('change', function () {
            var f = inp.files && inp.files[0];
            if (staffStyle) {
              nameEl.textContent = f ? ('Chosen: ' + f.name) : '';
            } else {
              nameEl.textContent = f ? f.name : 'No file chosen';
            }
            if (typeof onChange === 'function') onChange();
          });
        }
        wireBulkFileName('bulkRoster', 'bulkRosterName', function () {
          syncBulkRosterPicker();
          setBulkStepError('bulkStepRosterError', '');
        });
        wireBulkFileName('bulkEvidence', 'bulkEvidenceName', function () {
          syncBulkEvidencePicker();
          setBulkStepError('bulkStepEvidenceError', '');
        });
        wireBulkFileName('addTrainingEvidence', 'addTrainingEvidenceName', null, true);

        var bulkForm = document.getElementById('bulkForm');
        if (bulkForm) {
          bulkForm.addEventListener('reset', function () {
            window.setTimeout(function () {
              resetBulkWizard();
              void fillHrIssuingTrustFieldsIfEmpty();
              var st = document.getElementById('bulkStatus');
              if (st) {
                st.textContent = '';
                st.hidden = true;
                st.className = 'hr-muted hr-bulk-status--muted';
              }
              if (batchViz()) batchViz().clear(document.getElementById('bulkProvisionResult'));
              var wrap = document.getElementById('bulkTableWrap');
              var tb = document.getElementById('bulkResultsTbody');
              if (wrap) wrap.hidden = true;
              if (tb) tb.innerHTML = '';
            }, 0);
          });
        }

        function setBulkStatusMessage(msg, kind) {
          var statusEl = document.getElementById('bulkStatus');
          if (!statusEl) return;
          statusEl.hidden = false;
          statusEl.textContent = msg || '';
          statusEl.className = 'hr-bulk-status--muted';
          if (kind === 'error') statusEl.className = 'hr-bulk-status--error';
          else if (kind === 'ok') statusEl.className = 'hr-bulk-status--ok';
          else statusEl.classList.add('hr-muted');
        }

        var bulkSubmitBusy = false;
        var btnBulkSubmit = document.getElementById('bulkSubmit');
        var bulkFormEl = document.getElementById('bulkForm');
        if (bulkFormEl && btnBulkSubmit) {
          bulkFormEl.addEventListener('submit', async function (e) {
            e.preventDefault();
            if (bulkSubmitBusy) return;
            var statusEl = document.getElementById('bulkStatus');
            var wrap = document.getElementById('bulkTableWrap');
            var tbody = document.getElementById('bulkResultsTbody');
            var rosterEl = document.getElementById('bulkRoster');
            var evEl = document.getElementById('bulkEvidence');
            if (!bulkFormEl.reportValidity()) return;
            var cohortSel = document.getElementById('bulkCohort');
            var cohortId = bulkRecipientMethod === 'cohort' && cohortSel
              ? String(cohortSel.value || '').trim()
              : '';
            var hasRoster = bulkRecipientMethod === 'roster' && rosterEl && rosterEl.files && rosterEl.files[0];
            if (!cohortId && !hasRoster) {
              setBulkStatusMessage('Complete the recipient steps: choose a cohort or roster file.', 'error');
              setBulkWizardStep(bulkRecipientMethod === 'roster' ? 2 : 2);
              return;
            }
            if (!evEl || !evEl.files || !evEl.files[0]) {
              setBulkStatusMessage('Choose a class evidence file.', 'error');
              setBulkWizardStep(3);
              return;
            }
            bulkSubmitBusy = true;
            btnBulkSubmit.disabled = true;
            var bulkVizEl = document.getElementById('bulkProvisionResult');
            var bulkSt = document.getElementById('bulkStatus');
            if (bulkSt) bulkSt.hidden = true;
            if (batchViz()) batchViz().clear(bulkVizEl);
            var bulkStartMsg = 'Preparing bulk training issue…';
            if (cohortId) {
              var cohortOpt = cohortSel && cohortSel.options[cohortSel.selectedIndex];
              var cohortLabel = cohortOpt ? String(cohortOpt.textContent || '').trim() : '';
              if (cohortLabel) bulkStartMsg = 'Loading cohort “' + cohortLabel + '”…';
            } else if (hasRoster) {
              bulkStartMsg = 'Uploading roster file…';
            }
            if (batchViz()) batchViz().showLoading(bulkVizEl, bulkStartMsg);
            if (wrap) wrap.hidden = true;
            if (tbody) tbody.innerHTML = '';
            try {
              var fd = new FormData();
              if (cohortId) {
                fd.append('cohort_id', cohortId);
              } else if (hasRoster) {
                fd.append('roster', rosterEl.files[0]);
              }
              if (evEl && evEl.files && evEl.files[0]) fd.append('evidence', evEl.files[0]);
              fd.append('module_code', (bulkMod && bulkMod.value) ? bulkMod.value : 'fire_safety');
              fd.append('completion_date', (document.getElementById('bulkCompletion') || {}).value || '');
              fd.append('expiry_date', (document.getElementById('bulkExpiry') || {}).value || '');
              var ods = (document.getElementById('bulkOds') || {}).value;
              var iname = (document.getElementById('bulkIssuingName') || {}).value;
              if (ods && String(ods).trim()) fd.append('issuing_trust_ods_code', String(ods).trim());
              if (iname && String(iname).trim()) fd.append('issuing_trust_name', String(iname).trim());
              var data;
              if (batchViz() && batchViz().postNdjsonStream) {
                data = await batchViz().postNdjsonStream(
                  '/api/hr/bulk-training',
                  { formData: fd },
                  bulkVizEl
                );
              } else {
                var res = await fetch('/api/hr/bulk-training', { method: 'POST', body: fd, credentials: 'include' });
                var text = await res.text();
                data = null;
                try { data = text ? JSON.parse(text) : null; } catch (e2) { data = null; }
                if (!res.ok) {
                  var d = data && data.detail;
                  throw new Error(typeof d === 'string' ? d : (text || res.statusText));
                }
              }
              if (batchViz()) {
                batchViz().bulkTraining(bulkVizEl, data);
              } else {
                var errCount = Number(data.errors || 0);
                var aborted = Boolean(data.aborted);
                var summary =
                  'Issued: ' + String(data.issued || 0) +
                  ' · Skipped (duplicate): ' + String(data.skipped_duplicate || 0) +
                  ' · Errors: ' + String(errCount);
                if (aborted) {
                  setBulkStatusMessage(
                    'Nothing was saved. Fix the roster errors (or wallet size errors) and submit again. ' + summary,
                    'error'
                  );
                } else {
                  setBulkStatusMessage(summary, errCount > 0 ? 'error' : 'ok');
                }
              }
              if (wrap && tbody && data.rows && data.rows.length) {
                wrap.hidden = false;
                tbody.innerHTML = data.rows.map(function (r) {
                  return (
                    '<tr><td>' + esc(r.roster_line) + '</td><td>' + esc(r.status) + '</td><td>' + esc(r.message || '') + '</td></tr>'
                  );
                }).join('');
              }
            } catch (err) {
              if (batchViz()) batchViz().clear(bulkVizEl);
              if (bulkSt) bulkSt.hidden = false;
              setBulkStatusMessage(err.message || 'Request failed.', 'error');
            } finally {
              bulkSubmitBusy = false;
              btnBulkSubmit.disabled = false;
            }
          });
        }

        var btnBackToSearch = document.getElementById('btnBackToSearch');
        if (btnBackToSearch) {
          btnBackToSearch.addEventListener('click', function () {
            var addTr = document.getElementById('btnSearchDoctorAddTraining');
            if (addTr) addTr.hidden = true;
            show(document.getElementById('searchDoctorView'), false);
            show(document.getElementById('searchView'), true);
            if (HR_PAGE === 'search') {
              try {
                window.history.replaceState({}, '', '/static/hr/search.html');
              } catch (eHist2) {}
            }
          });
        }

        async function runDoctorSearch() {
          var inp = document.getElementById('doctorSearchInput');
          var statusEl = document.getElementById('searchStatus');
          var resultsEl = document.getElementById('searchResultsList');
          var q = (inp ? inp.value : '').trim();
          if (!q) { if (statusEl) statusEl.textContent = 'Enter a name, email, or GMC number.'; return; }
          if (statusEl) statusEl.textContent = 'Searching…';
          if (resultsEl) resultsEl.innerHTML = '';
          try {
            var data = await apiJson('/api/hr/doctors/search?q=' + encodeURIComponent(q) + '&limit=30');
            var results = data.results || [];
            if (statusEl) statusEl.textContent = results.length ? '' : 'No matching clinicians found.';
            if (!results.length) { if (resultsEl) resultsEl.innerHTML = ''; return; }
            if (resultsEl) {
              resultsEl.innerHTML = results.map(function (doc) {
                var name = esc(doc.display_name || doc.email || '—');
                var meta = [];
                if (doc.gmc_number) meta.push('GMC ' + esc(doc.gmc_number));
                if (doc.email) meta.push(esc(doc.email));
                if (doc.current_trust) meta.push(esc(doc.current_trust));
                return (
                  '<div class="hr-search-result-row">' +
                  '<div><div class="hr-search-result-name">' + name + '</div>' +
                  (meta.length ? '<div class="hr-search-result-meta">' + meta.join(' &middot; ') + '</div>' : '') +
                  '</div>' +
                  '<div class="hr-search-result-actions">' +
                  '<button type="button" class="nhsuk-button hr-btn-small" data-search-doctor-id="' + esc(String(doc.id)) + '" data-search-doctor-name="' + esc(doc.display_name || doc.email || '') + '">View training</button>' +
                  '<button type="button" class="nhsuk-button nhsuk-button--secondary hr-btn-small" data-add-doctor-id="' + esc(String(doc.id)) + '" data-add-doctor-name="' + esc(doc.display_name || doc.email || '') + '">Add training</button>' +
                  '<a class="nhsuk-button nhsuk-button--secondary hr-btn-small" href="/static/hr/messages/?doctor=' + encodeURIComponent(String(doc.id)) + '">Message</a>' +
                  '</div>' +
                  '</div>'
                );
              }).join('');

            }
          } catch (err) {
            if (statusEl) statusEl.textContent = err.message || 'Search failed.';
          }
        }

        async function openSearchDoctorView(doctorId, doctorName) {
          if (HR_PAGE === 'search') {
            try {
              window.history.replaceState({}, '', '/static/hr/search.html?doctor=' + encodeURIComponent(String(doctorId)));
            } catch (eHist) {}
          }
          show(document.getElementById('searchView'), false);
          show(document.getElementById('searchDoctorView'), true);
          var titleEl = document.getElementById('searchDoctorTitle');
          if (titleEl) titleEl.textContent = 'Verified training — ' + (doctorName || 'Doctor');
          var addTr = document.getElementById('btnSearchDoctorAddTraining');
          if (addTr) {
            addTr.hidden = false;
            addTr.setAttribute('data-doctor-id', String(doctorId));
            addTr.setAttribute('data-doctor-name', doctorName || '');
          }
          var metaBlock = document.getElementById('searchDoctorMetaBlock');
          if (metaBlock) metaBlock.innerHTML = '';
          var tbody = document.getElementById('searchDoctorItemsTbody');
          if (tbody) tbody.innerHTML = '<tr><td colspan="4" class="hr-muted">Loading…</td></tr>';
          try {
            var payload = await apiJson('/api/hr/doctors/' + encodeURIComponent(String(doctorId)) + '/training');
            var items = (payload.items || []).filter(function (it) {
              return (it.status || '').toLowerCase() === 'verified';
            });
            searchDoctorItemsCache = items;
            if (!items.length) {
              if (tbody) tbody.innerHTML = '<tr><td colspan="4" class="hr-muted">No verified records for this clinician yet.</td></tr>';
              return;
            }
            if (tbody) {
              tbody.innerHTML = items.map(function (it) {
                var name = esc(it.module_name || it.credential_id || '—');
                var expiry = it.expiry_date ? esc(String(it.expiry_date).slice(0, 10)) : '—';
                var issuer = it.issuing_trust_name ? '<div style="font-size:0.8125rem;color:var(--nhsuk-secondary-text);">Issuing: ' + esc(it.issuing_trust_name) + '</div>' : '';
                var verifiedAt = it.verified_by_trust_name ? '<div style="font-size:0.8125rem;color:var(--nhsuk-secondary-text);">HR verified at: ' + esc(it.verified_by_trust_name) + '</div>' : '';
                var evCell = it.certificate_base64
                  ? ('<button type="button" class="nhsuk-button nhsuk-button--secondary hr-btn-small" data-view-docs-cid="' +
                    esc(String(it.credential_id || '')) + '">View</button>')
                  : '—';
                return (
                  '<tr>' +
                  '<td>' + name + issuer + '</td>' +
                  '<td>' + expiry + '</td>' +
                  '<td><span class="hr-pill hr-pill--verified">Verified</span>' + verifiedAt + '</td>' +
                  '<td>' + evCell + '</td>' +
                  '</tr>'
                );
              }).join('');
            }
          } catch (err) {
            if (tbody) tbody.innerHTML = '<tr><td colspan="4" class="hr-muted">' + esc(err.message || 'Could not load.') + '</td></tr>';
          }
        }

        var btnDoctorSearch = document.getElementById('btnDoctorSearch');
        if (btnDoctorSearch) {
          btnDoctorSearch.addEventListener('click', runDoctorSearch);
        }
        var doctorSearchInput = document.getElementById('doctorSearchInput');
        if (doctorSearchInput) {
          doctorSearchInput.addEventListener('keydown', function (e) {
            if (e.key === 'Enter') { e.preventDefault(); runDoctorSearch(); }
          });
        }

        if (HR_PAGE === 'inbox') {
          var legQ = qs();
          if (legQ.get('search')) {
            var uLeg = new URL(window.location.href);
            uLeg.pathname = '/static/hr/search.html';
            uLeg.searchParams.delete('search');
            window.location.replace(uLeg.pathname + (uLeg.search || '') + uLeg.hash);
            return;
          }
          if (legQ.get('bulk')) {
            var uLeg2 = new URL(window.location.href);
            uLeg2.pathname = '/static/hr/bulk.html';
            uLeg2.searchParams.delete('bulk');
            window.location.replace(uLeg2.pathname + (uLeg2.search || '') + uLeg2.hash);
            return;
          }
        }

        var doctorId = qs().get('doctor');
        var sessionId = qs().get('session');

        if (HR_PAGE === 'search') {
          show(document.getElementById('searchView'), true);
          show(document.getElementById('searchDoctorView'), false);
          if (doctorId) {
            await openSearchDoctorView(doctorId, 'Clinician');
          }
          return;
        }

        if (HR_PAGE === 'bulk') {
          show(document.getElementById('bulkView'), true);
          await fillHrIssuingTrustFieldsIfEmpty();
          return;
        }

        /* HR_PAGE === 'inbox' */
        if (doctorId) {
          show(document.getElementById('sessionView'), true);
          show(document.getElementById('inboxView'), false);
          wireTabs('sessionView', function (tab) {
            itemsTab = tab === 'archived' ? 'archived' : 'new';
            if (lastSessionPayload) renderItemsTable(lastSessionPayload, null);
          });
          await loadDoctorQueue(doctorId);
        } else if (sessionId) {
          show(document.getElementById('sessionView'), true);
          show(document.getElementById('inboxView'), false);
          wireTabs('sessionView', function (tab) {
            itemsTab = tab === 'archived' ? 'archived' : 'new';
            if (lastSessionPayload) renderItemsTable(lastSessionPayload, sessionId);
          });
          await loadSession(sessionId);
        } else {
          show(document.getElementById('inboxView'), true);
          show(document.getElementById('sessionView'), false);
          wireTabs('inboxView', async function (tab) {
            inboxTab = tab === 'archived' ? 'archived' : 'new';
            await loadInbox();
          });
          await loadInbox();
        }
      })();
})();
