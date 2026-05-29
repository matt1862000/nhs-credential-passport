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

      function dedupeItemsByCredential(items) {
        var m = Object.create(null);
        (items || []).forEach(function (it) {
          var cid = String(it.credential_id || '');
          if (!cid) return;
          var prev = m[cid];
          if (!prev) {
            m[cid] = it;
            return;
          }
          var st = String(it.status || '').toUpperCase();
          var pst = String(prev.status || '').toUpperCase();
          if (pst === 'VERIFIED' && st === 'PENDING') m[cid] = it;
          else if (!prev.session_id && it.session_id) m[cid] = it;
        });
        return Object.keys(m).map(function (k) {
          return m[k];
        });
      }

      // Renders the decision-support block for an HR fit-review row.
      // Drops legacy "Semantic match (XX% similar)" text in favour of the
      // decision engine's natural-language reason, confidence label, match
      // chip, and historical precedent.
      function hrFitDecisionHtml(t) {
        if (!t || !t.decision) return '';

        var cls = 'hr-fit-decision';
        var icon = '\u2753';
        var title = 'Decision pending';
        if (t.decision === 'MEETS') {
          cls += ' hr-fit-decision--meets';
          icon = '\u2705';
          title = 'Meets requirement';
        } else if (t.decision === 'REQUIRES_REVIEW') {
          cls += ' hr-fit-decision--review';
          icon = '\u26A0\uFE0F';
          title = 'Needs review';
        } else {
          cls += ' hr-fit-decision--fail';
          icon = '\u274C';
          title = 'Does not meet';
        }

        var titleHtml =
          '<p class="hr-fit-decision__title">' +
          '<span aria-hidden="true">' + icon + '</span>' +
          '<span>' + esc(title) + '</span>' +
          '</p>';

        var confHtml = '';
        if (t.decision_confidence_label) {
          var cLabel = String(t.decision_confidence_label);
          var cText = cLabel.charAt(0).toUpperCase() + cLabel.slice(1);
          confHtml =
            '<div class="hr-fit-decision__conf">' +
            '<span class="hr-fit-decision__conf-label hr-fit-decision__conf-label--' + esc(cLabel) + '">' +
            esc(cText) + ' confidence</span>' +
            '<span class="hr-fit-decision__conf-reason">' + esc(t.decision_confidence_reason || '') + '</span>' +
            '</div>';
        }

        var whyHtml = t.decision_reason
          ? '<p class="hr-fit-decision__why">' + esc(t.decision_reason) + '</p>'
          : '';

        var chips = [];
        if (t.match_label) {
          var matchCls = 'hr-fit-chip';
          if (t.is_exact_match) matchCls += ' hr-fit-chip--match-exact';
          else if (String(t.match_label).indexOf('interpreted') !== -1) matchCls += ' hr-fit-chip--match-interpreted';
          chips.push('<span class="' + matchCls + '">Match: ' + esc(t.match_label) + '</span>');
        }
        if (t.historical_acceptance_hint) {
          var histCls = 'hr-fit-chip hr-fit-chip--hist';
          if (String(t.historical_acceptance_hint).indexOf('Limited') === 0) {
            histCls = 'hr-fit-chip hr-fit-chip--hist-low';
          }
          chips.push('<span class="' + histCls + '">' + esc(t.historical_acceptance_hint) + '</span>');
        }
        var crossCtx = t.historical_context && t.historical_context.cross_trust;
        if (crossCtx && crossCtx.sample_size >= 5 && crossCtx.rate != null) {
          chips.push(
            '<span class="hr-fit-chip hr-fit-chip--cross">' +
            'Similar trusts: ' + Math.round(crossCtx.rate * 100) + '% (' +
            esc(String(crossCtx.accepted)) + '/' + esc(String(crossCtx.sample_size)) +
            ')</span>'
          );
        }
        var chipsHtml = chips.length
          ? '<div class="hr-fit-decision__chips">' + chips.join('') + '</div>'
          : '';

        return '<div class="' + cls + '">' + titleHtml + confHtml + whyHtml + chipsHtml + '</div>';
      }

      function evidenceStatusPill(it) {
        var st = String(it.status || '').toUpperCase();
        if (st === 'VERIFIED') {
          return '<span class="hr-pill hr-pill--verified">VERIFIED</span>';
        }
        if (st === 'DECLINED') {
          return '<span class="hr-pill">DECLINED</span>';
        }
        if (st === 'NOT_SHARED') {
          return '<span class="hr-pill">NOT SHARED</span>';
        }
        return (
          '<span class="hr-pill">PENDING</span>' +
          (it.is_resubmission ? '<span class="hr-pill hr-pill--resubmit">Resubmission</span>' : '')
        );
      }

      function renderMandatoryFitSection(payload) {
        var section = document.getElementById('mandatoryFitSection');
        var body = document.getElementById('mandatoryFitSectionBody');
        if (!section || !body) return;
        var doctorId = payload && payload.doctor_user_id;
        var rows = [];
        (payload && payload.items || []).forEach(function (it) {
          if (String(it.status || '').toUpperCase() !== 'VERIFIED') return;
          (it.mandatory_needs_review || []).forEach(function (t) {
            rows.push({ item: it, topic: t });
          });
        });
        if (!rows.length || doctorId == null) {
          section.hidden = true;
          body.innerHTML = '';
          return;
        }
        section.hidden = false;
        var tableRows = rows
          .map(function (row) {
            var it = row.item;
            var t = row.topic;
            var credId = String(it.credential_id || '');
            var sidVal = it.session_id != null ? String(it.session_id) : '';
            var moduleCell = moduleEvidenceLinkHtml(it, sidVal, payload);
            var topicName = esc(t.topic_name || 'Mandatory requirement');
            var decisionHtml = hrFitDecisionHtml(t);
            // Legacy reason text only shown when API row has no decision envelope.
            var legacyReason = (!t.decision && t.reason)
              ? '<p class="hr-mandatory-fit-section__reason">' + esc(t.reason) + '</p>'
              : '';
            return (
              '<tr>' +
              '<td>' + moduleCell + '</td>' +
              '<td>' + evidenceStatusPill(it) + '</td>' +
              '<td>' + topicName + legacyReason + decisionHtml + '</td>' +
              '<td>' +
              '<div class="hr-mandatory-fit-actions">' +
              '<button type="button" class="nhsuk-button hr-btn-small" data-fit-accept="1" data-cid="' +
              esc(credId) +
              '" data-doctor-id="' +
              esc(String(doctorId)) +
              '" data-topic-id="' +
              esc(t.topic_id != null ? String(t.topic_id) : '') +
              '" data-topic-name="' +
              esc(t.topic_name || '') +
              '">Satisfies requirement</button>' +
              '<button type="button" class="nhsuk-button nhsuk-button--secondary hr-btn-small" data-fit-reject="1" data-cid="' +
              esc(credId) +
              '" data-doctor-id="' +
              esc(String(doctorId)) +
              '" data-topic-id="' +
              esc(t.topic_id != null ? String(t.topic_id) : '') +
              '" data-topic-name="' +
              esc(t.topic_name || '') +
              '">Does not satisfy</button>' +
              '</div>' +
              '</td>' +
              '</tr>'
            );
          })
          .join('');
        body.innerHTML =
          '<div class="hr-table-wrap">' +
          '<table class="hr-table" aria-label="Requirement fit review">' +
          '<thead><tr><th scope="col">Training record</th><th scope="col">Evidence status</th><th scope="col">Trust requirement</th><th scope="col">Requirement fit</th></tr></thead>' +
          '<tbody>' +
          tableRows +
          '</tbody></table></div>';
      }

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

      /** Merge inbox rows that belong to the same doctor (multiple share sessions). */
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
            module_names: mergeModuleNameLists(sess.map(function (x) { return x.module_names; })),
            pending_module_names: mergeModuleNameLists(sess.map(function (x) { return x.pending_module_names; })),
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

      var hrDoctorSuggestWired = Object.create(null);

      function doctorSuggestMeta(doc) {
        var parts = [];
        if (doc.gmc_number) parts.push('GMC ' + doc.gmc_number);
        if (doc.email) parts.push(doc.email);
        var trust = doc.current_trust_display || doc.current_trust;
        if (trust) parts.push(trust);
        return parts.join(' · ');
      }

      function wireHrDoctorSearchSuggest(opts) {
        var inputId = opts.inputId;
        var listId = opts.listId;
        var wrapId = opts.wrapId;
        if (hrDoctorSuggestWired[inputId]) return;
        var inputEl = document.getElementById(inputId);
        var listEl = document.getElementById(listId);
        var wrapEl = document.getElementById(wrapId);
        if (!inputEl || !listEl || !wrapEl) return;
        hrDoctorSuggestWired[inputId] = true;

        var items = [];
        var active = -1;
        var debSuggest = null;
        var minLen = opts.minLength != null ? opts.minLength : 2;
        var limit = opts.limit != null ? opts.limit : 8;

        function hideList() {
          listEl.innerHTML = '';
          listEl.hidden = true;
          active = -1;
          items = [];
          inputEl.setAttribute('aria-expanded', 'false');
          inputEl.removeAttribute('aria-activedescendant');
        }

        function updateHighlight() {
          var lis = listEl.querySelectorAll('li[role="option"]');
          for (var j = 0; j < lis.length; j++) {
            lis[j].setAttribute('aria-selected', j === active ? 'true' : 'false');
          }
          if (active >= 0 && lis[active]) {
            inputEl.setAttribute('aria-activedescendant', lis[active].id);
            try {
              lis[active].scrollIntoView({ block: 'nearest' });
            } catch (eSc) {}
          } else {
            inputEl.removeAttribute('aria-activedescendant');
          }
        }

        function applyIndex(idx) {
          if (idx < 0 || idx >= items.length) return;
          var doc = items[idx];
          hideList();
          if (typeof opts.onSelect === 'function') opts.onSelect(doc);
        }

        function renderList(docs) {
          items = docs || [];
          listEl.innerHTML = '';
          active = -1;
          if (!items.length) {
            hideList();
            return;
          }
          for (var i = 0; i < items.length; i++) {
            var doc = items[i];
            var li = document.createElement('li');
            li.setAttribute('role', 'option');
            li.id = listId + '-opt-' + i;
            li.dataset.index = String(i);
            var nameSpan = document.createElement('span');
            nameSpan.textContent = doc.display_name || doc.email || 'Doctor';
            li.appendChild(nameSpan);
            var metaText = doctorSuggestMeta(doc);
            if (metaText) {
              var meta = document.createElement('span');
              meta.className = 'nhs-suggest-meta';
              meta.textContent = metaText;
              li.appendChild(meta);
            }
            listEl.appendChild(li);
          }
          listEl.hidden = false;
          inputEl.setAttribute('aria-expanded', 'true');
        }

        async function runSuggest() {
          var q = String(inputEl.value || '').trim();
          if (q.length < minLen) {
            hideList();
            return;
          }
          try {
            var data = await apiJson('/api/hr/doctors/search?q=' + encodeURIComponent(q) + '&limit=' + limit);
            renderList(data.results || []);
          } catch (e) {
            hideList();
          }
        }

        inputEl.addEventListener('input', function () {
          if (debSuggest) clearTimeout(debSuggest);
          debSuggest = setTimeout(function () {
            debSuggest = null;
            void runSuggest();
          }, 280);
        });
        listEl.addEventListener('mousedown', function (ev) {
          if (ev.target.closest('li[role="option"]')) ev.preventDefault();
        });
        listEl.addEventListener('click', function (ev) {
          var li = ev.target.closest('li[role="option"]');
          if (!li) return;
          applyIndex(parseInt(li.dataset.index, 10));
        });
        inputEl.addEventListener('keydown', function (e) {
          if (!listEl.hidden && items.length) {
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
              return;
            }
            if (e.key === 'ArrowUp') {
              e.preventDefault();
              active = Math.max(active - 1, 0);
              updateHighlight();
              return;
            }
            if (e.key === 'Enter' && active >= 0) {
              e.preventDefault();
              applyIndex(active);
              return;
            }
          }
          if (e.key === 'Enter' && typeof opts.onEnter === 'function') {
            e.preventDefault();
            hideList();
            opts.onEnter();
          }
        });
        inputEl.addEventListener('blur', function () {
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

      var LS_INBOX_TAB = 'hr_tab_inbox';
      var LS_ITEMS_TAB = 'hr_tab_items';
      var inboxTab = 'new';
      var itemsTab = 'new';
      var inboxFilterModule = '';
      var inboxFilterStatus = '';
      var itemsFilterModule = '';
      var itemsFilterStatus = '';
      var lastInboxGroups = [];
      var lastSessionPayload = null;
      var lastItemsFixedSessionId = null;
      var HR_POLL_MS = 15000;
      var _hrSessionPollTimer = null;
      var _hrSessionPollInFlight = false;
      var _hrSessionActionInFlight = false;
      var _hrInboxPollTimer = null;
      var _hrInboxPollInFlight = false;

      function stopInboxPoll() {
        if (_hrInboxPollTimer) {
          clearInterval(_hrInboxPollTimer);
          _hrInboxPollTimer = null;
        }
      }

      function startInboxPoll() {
        stopInboxPoll();
        var inboxView = document.getElementById('inboxView');
        if (!inboxView || inboxView.hidden) return;
        _hrInboxPollTimer = setInterval(function () {
          if (document.hidden) return;
          if (_hrInboxPollInFlight) return;
          var iv = document.getElementById('inboxView');
          if (!iv || iv.hidden) {
            stopInboxPoll();
            return;
          }
          void pollInboxQuiet();
        }, HR_POLL_MS);
      }

      async function pollInboxQuiet() {
        _hrInboxPollInFlight = true;
        try {
          await loadInbox(true);
        } catch (e) {
          console.warn('HR inbox poll failed', e);
        } finally {
          _hrInboxPollInFlight = false;
        }
      }

      function stopSessionViewPoll() {
        if (_hrSessionPollTimer) {
          clearInterval(_hrSessionPollTimer);
          _hrSessionPollTimer = null;
        }
      }

      function startSessionViewPoll(fixedSessionId) {
        stopSessionViewPoll();
        var sessionView = document.getElementById('sessionView');
        if (!sessionView || sessionView.hidden) return;
        _hrSessionPollTimer = setInterval(function () {
          if (document.hidden) return;
          if (_hrSessionActionInFlight || _hrSessionPollInFlight) return;
          var sv = document.getElementById('sessionView');
          if (!sv || sv.hidden) {
            stopSessionViewPoll();
            return;
          }
          void pollSessionViewQuiet(fixedSessionId);
        }, HR_POLL_MS);
      }

      async function pollSessionViewQuiet(fixedSessionId) {
        _hrSessionPollInFlight = true;
        try {
          await refreshPayloadAfterAction(fixedSessionId);
          renderMandatoryFitSection(lastSessionPayload);
        } catch (e) {
          console.warn('HR verify view poll failed', e);
        } finally {
          _hrSessionPollInFlight = false;
        }
      }

      function itemsTableColspan(showSelectCol) {
        return showSelectCol ? 5 : 4;
      }

      function isItemActionable(it, merged, portfolioSession) {
        if (it.fit_review_only && !it.session_id) return false;
        var st = String(it.status || '').toUpperCase();
        if (st === 'VERIFIED' || st === 'DECLINED' || st === 'NOT_SHARED') return false;
        var portfolioRow = merged
          ? String(it.session_share_kind || '').toLowerCase() === 'portfolio'
          : portfolioSession;
        return !portfolioRow;
      }

      function syncItemsBulkBarCounts() {
        var tbody = document.getElementById('itemsTbody');
        var bulkBar = document.getElementById('itemsBulkBar');
        if (!tbody || !bulkBar || bulkBar.hidden) return;
        var all = tbody.querySelectorAll('.hr-item-select-cb[data-cid]');
        var checked = tbody.querySelectorAll('.hr-item-select-cb[data-cid]:checked');
        var n = checked.length;
        var countEl = document.getElementById('itemsBulkCount');
        var btnV = document.getElementById('btnItemsVerifySelected');
        var btnD = document.getElementById('btnItemsDeclineSelected');
        var selectAll = document.getElementById('itemsSelectAll');
        if (countEl) {
          countEl.textContent = n === 0 ? '0 selected' : (n === 1 ? '1 selected' : n + ' selected');
        }
        if (btnV) btnV.disabled = n === 0;
        if (btnD) btnD.disabled = n === 0;
        if (selectAll) {
          selectAll.indeterminate = n > 0 && n < all.length;
          selectAll.checked = all.length > 0 && n === all.length;
        }
      }

      function updateItemsBulkControls(showSelectCol) {
        var bulkBar = document.getElementById('itemsBulkBar');
        var th = document.getElementById('itemsSelectAllTh');
        var selectAll = document.getElementById('itemsSelectAll');
        if (th) th.hidden = !showSelectCol;
        if (bulkBar) bulkBar.hidden = !showSelectCol;
        if (selectAll) {
          selectAll.checked = false;
          selectAll.indeterminate = false;
        }
        syncItemsBulkBarCounts();
      }

      function selectedItemEntries() {
        var tbody = document.getElementById('itemsTbody');
        if (!tbody) return [];
        return Array.from(tbody.querySelectorAll('.hr-item-select-cb[data-cid]:checked')).map(function (cb) {
          return {
            sid: cb.getAttribute('data-sid'),
            cid: cb.getAttribute('data-cid'),
          };
        }).filter(function (e) {
          return e.sid && e.cid;
        });
      }

      function notifyHrInboxChanged() {
        if (window.NHSNavAccount && typeof NHSNavAccount.notifyVerifyInboxChanged === 'function') {
          NHSNavAccount.notifyVerifyInboxChanged();
        }
        if (window.NHSNavAccount && typeof NHSNavAccount.notifyAlertsChanged === 'function') {
          NHSNavAccount.notifyAlertsChanged();
        }
      }

      async function runBulkVerify(entries) {
        if (!entries.length) return;
        if (!confirm('Verify ' + entries.length + ' selected record' + (entries.length === 1 ? '' : 's') + '?')) return;
        var btn = document.getElementById('btnItemsVerifySelected');
        if (btn) {
          btn.disabled = true;
          btn.textContent = 'Verifying…';
        }
        _hrSessionActionInFlight = true;
        var failed = 0;
        try {
          for (var i = 0; i < entries.length; i++) {
            try {
              await apiJson(
                '/api/hr/shares/' +
                  encodeURIComponent(entries[i].sid) +
                  '/items/' +
                  encodeURIComponent(entries[i].cid) +
                  '/verify',
                { method: 'POST' }
              );
            } catch (err) {
              failed++;
            }
          }
          await refreshPayloadAfterAction(lastItemsFixedSessionId);
          notifyHrInboxChanged();
          if (failed) alert('Could not verify ' + failed + ' record(s). The rest were updated.');
        } finally {
          _hrSessionActionInFlight = false;
          if (btn) btn.textContent = 'Verify selected';
          syncItemsBulkBarCounts();
        }
      }

      async function runBulkDecline(entries) {
        if (!entries.length) return;
        var reason = (prompt('Why are you declining these records? (Sent back to the doctor)') || '').trim();
        if (!reason) return;
        var btn = document.getElementById('btnItemsDeclineSelected');
        if (btn) {
          btn.disabled = true;
          btn.textContent = 'Declining…';
        }
        _hrSessionActionInFlight = true;
        var failed = 0;
        try {
          for (var i = 0; i < entries.length; i++) {
            try {
              await apiJson(
                '/api/hr/shares/' +
                  encodeURIComponent(entries[i].sid) +
                  '/items/' +
                  encodeURIComponent(entries[i].cid) +
                  '/decline',
                {
                  method: 'POST',
                  headers: { 'Content-Type': 'application/json' },
                  body: JSON.stringify({ reason: reason }),
                }
              );
            } catch (err) {
              failed++;
            }
          }
          await refreshPayloadAfterAction(lastItemsFixedSessionId);
          notifyHrInboxChanged();
          if (failed) alert('Could not decline ' + failed + ' record(s). The rest were updated.');
        } finally {
          _hrSessionActionInFlight = false;
          if (btn) btn.textContent = 'Decline selected';
          syncItemsBulkBarCounts();
        }
      }

      function wireItemsBulkHandlers() {
        var selectAll = document.getElementById('itemsSelectAll');
        var tbody = document.getElementById('itemsTbody');
        var btnV = document.getElementById('btnItemsVerifySelected');
        var btnD = document.getElementById('btnItemsDeclineSelected');
        if (selectAll && !selectAll._hrBulkWired) {
          selectAll._hrBulkWired = true;
          selectAll.addEventListener('change', function () {
            if (!tbody) return;
            var on = !!selectAll.checked;
            tbody.querySelectorAll('.hr-item-select-cb[data-cid]').forEach(function (cb) {
              cb.checked = on;
            });
            syncItemsBulkBarCounts();
          });
        }
        if (tbody && !tbody._hrBulkChangeWired) {
          tbody._hrBulkChangeWired = true;
          tbody.addEventListener('change', function (e) {
            if (e.target && e.target.classList && e.target.classList.contains('hr-item-select-cb') && e.target.getAttribute('data-cid')) {
              syncItemsBulkBarCounts();
            }
          });
        }
        if (btnV && !btnV._hrBulkWired) {
          btnV._hrBulkWired = true;
          btnV.addEventListener('click', function () {
            void runBulkVerify(selectedItemEntries());
          });
        }
        if (btnD && !btnD._hrBulkWired) {
          btnD._hrBulkWired = true;
          btnD.addEventListener('click', function () {
            void runBulkDecline(selectedItemEntries());
          });
        }
      }

      function mergeModuleNameLists(lists) {
        var seen = Object.create(null);
        var out = [];
        (lists || []).forEach(function (arr) {
          (arr || []).forEach(function (n) {
            var k = String(n || '').trim();
            if (!k || seen[k]) return;
            seen[k] = true;
            out.push(k);
          });
        });
        return out.sort(function (a, b) {
          return a.localeCompare(b, undefined, { sensitivity: 'base' });
        });
      }

      function loadStoredTab(key, fallback) {
        try {
          var v = localStorage.getItem(key);
          return v === 'archived' ? 'archived' : v === 'new' ? 'new' : fallback;
        } catch (e) {
          return fallback;
        }
      }

      function saveStoredTab(key, tab) {
        try {
          localStorage.setItem(key, tab === 'archived' ? 'archived' : 'new');
        } catch (e) { /* ignore */ }
      }

      function setSegmentTab(containerId, tab) {
        var root = document.getElementById(containerId);
        if (!root) return;
        var wanted = tab === 'archived' ? 'archived' : 'new';
        Array.from(root.querySelectorAll('button[data-tab]')).forEach(function (x) {
          var active = x.getAttribute('data-tab') === wanted;
          x.classList.toggle('active', active);
          x.setAttribute('aria-selected', active ? 'true' : 'false');
        });
      }

      function filterInboxGroups(groups) {
        return (groups || []).filter(function (g) {
          if (inboxFilterStatus === 'pending' && !(g.pending_count > 0)) return false;
          if (inboxFilterStatus === 'declined' && !(g.declined_count > 0)) return false;
          if (inboxFilterStatus === 'no_pending' && g.pending_count > 0) return false;
          if (inboxFilterModule) {
            var names =
              g.pending_module_names && g.pending_module_names.length
                ? g.pending_module_names
                : g.module_names || [];
            if (names.indexOf(inboxFilterModule) < 0) return false;
          }
          return true;
        });
      }

      function fillInboxModuleSelect(groups) {
        var sel = document.getElementById('inboxFilterModule');
        if (!sel) return;
        var names = mergeModuleNameLists(
          (groups || []).map(function (g) {
            return g.pending_module_names && g.pending_module_names.length
              ? g.pending_module_names
              : g.module_names;
          })
        );
        var cur = inboxFilterModule;
        sel.innerHTML =
          '<option value="">All modules</option>' +
          names
            .map(function (n) {
              return (
                '<option value="' +
                esc(n).replace(/"/g, '&quot;') +
                '">' +
                esc(n) +
                '</option>'
              );
            })
            .join('');
        if (cur && names.indexOf(cur) >= 0) sel.value = cur;
      }

      function fillItemsModuleSelect(payload) {
        var sel = document.getElementById('itemsFilterModule');
        if (!sel || !payload) return;
        var names = mergeModuleNameLists(
          (payload.items || []).map(function (it) {
            return it.module_name ? [it.module_name] : [];
          })
        );
        var cur = itemsFilterModule;
        sel.innerHTML =
          '<option value="">All modules</option>' +
          names
            .map(function (n) {
              return (
                '<option value="' +
                esc(n).replace(/"/g, '&quot;') +
                '">' +
                esc(n) +
                '</option>'
              );
            })
            .join('');
        if (cur && names.indexOf(cur) >= 0) sel.value = cur;
      }

      function closeHrCertModal() {
        var modal = document.getElementById('hrCertModal');
        var body = document.getElementById('hrCertModalBody');
        if (body && body.dataset.certBlobUrl) {
          try { URL.revokeObjectURL(body.dataset.certBlobUrl); } catch (e) {}
          delete body.dataset.certBlobUrl;
        }
        if (body) body.innerHTML = '';
        if (modal) modal.hidden = true;
      }

      function evidenceMimeFromBytes(bytes, filename) {
        if (bytes.length >= 4 && bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46) {
          return 'application/pdf';
        }
        if (bytes.length >= 8 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) {
          return 'image/png';
        }
        if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
          return 'image/jpeg';
        }
        if (bytes.length >= 12 && bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x46 &&
            bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50) {
          return 'image/webp';
        }
        var fn = String(filename || '').toLowerCase();
        var ext = (fn.split('.').pop() || '').toLowerCase();
        if (ext === 'pdf') return 'application/pdf';
        if (ext === 'png') return 'image/png';
        if (ext === 'webp') return 'image/webp';
        return 'image/jpeg';
      }

      function resolveHrEvidenceItem(payload, cid, sid) {
        var items = (payload && payload.items) || [];
        var base = items.find(function (x) { return String(x.credential_id) === String(cid); }) || null;
        if (base && base.certificate_base64 && String(base.certificate_base64).trim()) {
          return base;
        }
        if (sid) {
          var sameSession = items.find(function (x) {
            return String(x.session_id) === String(sid) &&
              x.certificate_base64 &&
              String(x.certificate_base64).trim();
          });
          if (sameSession) {
            return Object.assign({}, base || {}, {
              module_name: (base && base.module_name) || sameSession.module_name,
              certificate_base64: sameSession.certificate_base64,
              certificate_filename: sameSession.certificate_filename || 'evidence',
            });
          }
        }
        var any = items.find(function (x) {
          return x.certificate_base64 && String(x.certificate_base64).trim();
        });
        if (any) {
          return Object.assign({}, base || {}, {
            module_name: (base && base.module_name) || any.module_name,
            certificate_base64: any.certificate_base64,
            certificate_filename: any.certificate_filename || 'evidence',
          });
        }
        return base;
      }

      function itemHasViewableEvidence(it, sid, payload) {
        if (!it) return false;
        var sidVal = sid != null && sid !== '' ? String(sid) : (it.session_id != null ? String(it.session_id) : '');
        var resolved = resolveHrEvidenceItem(payload, it.credential_id, sidVal);
        return !!(resolved && resolved.certificate_base64 && String(resolved.certificate_base64).trim());
      }

      function moduleEvidenceLinkHtml(it, sid, payload) {
        var label = esc(it.module_name || it.credential_id || '—');
        var sidVal = sid != null && sid !== '' ? String(sid) : (it.session_id != null ? String(it.session_id) : '');
        if (!itemHasViewableEvidence(it, sidVal, payload)) return label;
        return (
          '<a href="#" class="hr-module-name-btn" data-view-cert="1" data-cid="' +
          esc(String(it.credential_id || '')) +
          '" data-sid="' +
          esc(sidVal) +
          '" title="View evidence for this record">' +
          label +
          '</a>'
        );
      }

      var _pdfJsLoadPromise = null;

      function ensurePdfJsLoaded() {
        if (window.pdfjsLib) {
          window.pdfjsLib.GlobalWorkerOptions.workerSrc = '/static/shared/vendor/pdf.worker.min.js';
          return Promise.resolve(window.pdfjsLib);
        }
        if (_pdfJsLoadPromise) return _pdfJsLoadPromise;
        _pdfJsLoadPromise = new Promise(function (resolve, reject) {
          var s = document.createElement('script');
          s.src = '/static/shared/vendor/pdf.min.js';
          s.onload = function () {
            if (!window.pdfjsLib) {
              reject(new Error('PDF.js failed to load'));
              return;
            }
            window.pdfjsLib.GlobalWorkerOptions.workerSrc = '/static/shared/vendor/pdf.worker.min.js';
            resolve(window.pdfjsLib);
          };
          s.onerror = function () { reject(new Error('PDF.js failed to load')); };
          document.head.appendChild(s);
        });
        return _pdfJsLoadPromise;
      }

      function pdfPreviewTargetWidth(container) {
        var panel = container && container.closest('.hr-modal__panel');
        if (panel && panel.clientWidth > 240) {
          return Math.max(320, panel.clientWidth - 56);
        }
        return Math.min(860, Math.max(320, Math.floor(window.innerWidth * 0.9) - 56));
      }

      function afterModalLayout(fn) {
        requestAnimationFrame(function () {
          requestAnimationFrame(fn);
        });
      }

      function renderHrPdfCanvasPreview(container, bytes, renderToken) {
        if (!container) return Promise.resolve();
        container.dataset.renderToken = String(renderToken);
        return ensurePdfJsLoaded()
          .then(function (pdfjsLib) {
            if (container.dataset.renderToken !== String(renderToken)) return null;
            return pdfjsLib.getDocument({ data: bytes }).promise;
          })
          .then(function (pdf) {
            if (!pdf || container.dataset.renderToken !== String(renderToken)) return;
            container.innerHTML = '';
            var chain = Promise.resolve();
            for (var pageNum = 1; pageNum <= pdf.numPages; pageNum++) {
              (function (n) {
                chain = chain.then(function () {
                  if (container.dataset.renderToken !== String(renderToken)) return;
                  return pdf.getPage(n).then(function (page) {
                    return new Promise(function (resolve) {
                      afterModalLayout(function () {
                        if (container.dataset.renderToken !== String(renderToken)) {
                          resolve();
                          return;
                        }
                        var outputScale = window.devicePixelRatio || 1;
                        var baseViewport = page.getViewport({ scale: 1 });
                        var maxWidth = pdfPreviewTargetWidth(container);
                        var displayScale = maxWidth / baseViewport.width;
                        if (displayScale > 2.5) displayScale = 2.5;
                        var viewport = page.getViewport({ scale: displayScale });
                        var canvas = document.createElement('canvas');
                        canvas.className = 'hr-cert-pdf-page';
                        canvas.width = Math.floor(viewport.width * outputScale);
                        canvas.height = Math.floor(viewport.height * outputScale);
                        canvas.style.width = Math.floor(viewport.width) + 'px';
                        canvas.style.height = Math.floor(viewport.height) + 'px';
                        container.appendChild(canvas);
                        var transform = outputScale !== 1 ? [outputScale, 0, 0, outputScale, 0, 0] : null;
                        page.render({
                          canvasContext: canvas.getContext('2d'),
                          viewport: viewport,
                          transform: transform,
                        }).promise.then(resolve, resolve);
                      });
                    });
                  });
                });
              })(pageNum);
            }
            return chain;
          })
          .catch(function () {
            if (container.dataset.renderToken !== String(renderToken)) return;
            container.innerHTML =
              '<p class="hr-muted" style="margin:0;">Preview unavailable. Use <strong>Open PDF in new tab</strong> above.</p>';
          });
      }

      function renderHrCertificatePreview(body, b64, mime, filename) {
        if (body && body.dataset.certBlobUrl) {
          try { URL.revokeObjectURL(body.dataset.certBlobUrl); } catch (e) {}
          delete body.dataset.certBlobUrl;
        }
        body.dataset.certRenderToken = String(Date.now());
        var clean = String(b64 || '').replace(/\s/g, '');
        if (!clean) return false;
        var bin = atob(clean);
        var bytes = new Uint8Array(bin.length);
        for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
        mime = evidenceMimeFromBytes(bytes, filename);
        var blob = new Blob([bytes], { type: mime });
        var url = URL.createObjectURL(blob);
        body.dataset.certBlobUrl = url;
        var safeName = String(filename || 'evidence').replace(/"/g, '');
        if (mime === 'application/pdf') {
          var renderToken = String(Date.now());
          body.dataset.certRenderToken = renderToken;
          body.innerHTML =
            '<p class="hr-muted" style="margin:0 0 0.75rem 0;">' +
            '<a href="' + url + '" target="_blank" rel="noopener">Open PDF in new tab</a>' +
            ' · <a href="' + url + '" download="' + safeName + '">Download</a>' +
            '</p>' +
            '<div class="hr-cert-pdf-view" aria-live="polite">Loading preview…</div>';
          void renderHrPdfCanvasPreview(body.querySelector('.hr-cert-pdf-view'), bytes, renderToken);
        } else {
          body.innerHTML = '<img class="hr-cert-img" alt="Uploaded evidence" src="' + url + '" />';
        }
        return true;
      }

      function openHrCertModal(it) {
        var modal = document.getElementById('hrCertModal');
        var title = document.getElementById('hrCertModalTitle');
        var body = document.getElementById('hrCertModalBody');
        if (!modal || !body || !it || !it.certificate_base64) return;
        var name = (it.module_name || it.credential_id || 'Evidence').trim();
        if (title) title.textContent = name;
        var fn = String(it.certificate_filename || 'evidence');
        var mime = evidenceMimeFromBytes(new Uint8Array(0), fn);
        modal.hidden = false;
        if (!renderHrCertificatePreview(body, it.certificate_base64, mime, fn)) {
          modal.hidden = true;
          return;
        }
      }

      function closeHrAddTrainingModal() {
        var m = document.getElementById('hrAddTrainingModal');
        if (m) m.hidden = true;
      }

      function wireTabs(containerId, storageKey, onPick) {
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
          if (storageKey) saveStoredTab(storageKey, wanted);
          onPick(wanted);
        });
      }

      function ingestInboxSharesData(data) {
        var all = (data.sessions || []);
        var sessions = all.filter(function (s) {
          var sk = String(s.share_kind || 'review').toLowerCase();
          var isPortfolio = sk === 'portfolio';
          var hasPending = (s.pending_count || 0) > 0;
          if (inboxTab === 'new') return !isPortfolio && hasPending;
          return !isPortfolio && !hasPending;
        });
        lastInboxGroups = aggregateDoctorGroups(sessions);
        fillInboxModuleSelect(lastInboxGroups);
      }

      async function loadInbox(quiet) {
        var tbody = document.getElementById('sessionsTbody');
        var summaryEl = document.getElementById('inboxSummary');
        if (!quiet) {
          if (tbody) tbody.innerHTML = '<tr><td colspan="4" class="hr-muted">Loading…</td></tr>';
          if (summaryEl) summaryEl.textContent = '';
        }
        var data = await apiJson('/api/hr/shares?limit=200');
        ingestInboxSharesData(data);
        rerenderInboxFromCache();
      }

      function rerenderInboxFromCache() {
        var tbody = document.getElementById('sessionsTbody');
        var summaryEl = document.getElementById('inboxSummary');
        fillInboxModuleSelect(lastInboxGroups);
        var groups = filterInboxGroups(lastInboxGroups);
        if (summaryEl) {
          if (inboxTab === 'new') {
            if (groups.length === 0) {
              summaryEl.innerHTML = lastInboxGroups.length
                ? 'No doctors match the current filters.'
                : 'Nothing waiting — <strong>all caught up</strong> for now.';
            } else if (groups.length === 1) {
              summaryEl.innerHTML = '<strong>1</strong> doctor still has records to verify.';
            } else {
              summaryEl.innerHTML =
                '<strong>' + String(groups.length) + '</strong> doctors still have records to verify.';
            }
          } else {
            summaryEl.innerHTML =
              groups.length === 0
                ? (lastInboxGroups.length ? 'No doctors match the current filters.' : 'No completed sets in this list yet.')
                : '<strong>' + String(groups.length) + '</strong> doctor(s) with every submission fully verified or declined.';
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
        if (tbody) {
          tbody.innerHTML =
            rows ||
            '<tr><td colspan="4" class="hr-muted">' +
              (inboxTab === 'new' ? 'No sets need action right now.' : 'No completed sets to show.') +
              (lastInboxGroups.length && groups.length < lastInboxGroups.length
                ? ' (filters hide ' + (lastInboxGroups.length - groups.length) + '.)'
                : '') +
              '</td></tr>';
        }
      }

      /**
       * @param fixedSessionId When set, single-session review (/api/hr/shares/:id). When null, merged doctor queue (each item carries session_id).
       */
      function renderItemsTable(payload, fixedSessionId) {
        var tbody = document.getElementById('itemsTbody');
        var s = payload;
        var merged = fixedSessionId == null || fixedSessionId === '';
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
              '<strong>Reference pack</strong> — already verified by HR at the doctor&rsquo;s other employer. View-only here; no verify or decline.</div>';
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
        fillItemsModuleSelect(s);
        renderMandatoryFitSection(s);
        var sourceItems = dedupeItemsByCredential(s.items || []);
        var items = sourceItems.filter(function (it) {
          var st = String(it.status || '').toUpperCase();
          var pending = st !== 'VERIFIED' && st !== 'DECLINED';
          var pr = merged
            ? String(it.session_share_kind || '').toLowerCase() === 'portfolio'
            : portfolioSession;
          var tabOk = pr ? itemsTab === 'new' : itemsTab === 'new' ? pending : !pending;
          if (!tabOk) return false;
          if (itemsFilterModule && String(it.module_name || '') !== itemsFilterModule) return false;
          if (itemsFilterStatus && st !== itemsFilterStatus) return false;
          return true;
        });
        var showSelectCol =
          itemsTab === 'new' &&
          items.some(function (it) {
            return isItemActionable(it, merged, portfolioSession);
          });
        var colspan = itemsTableColspan(showSelectCol);
        updateItemsBulkControls(showSelectCol);
        var prevSid = null;
        var parts = [];
        items.forEach(function (it) {
          if (merged && (s.session_ids || []).length > 1 && it.session_id != null && it.session_id !== prevSid) {
            prevSid = it.session_id;
            var when = formatSharedAt(it.session_created_at);
            parts.push(
              '<tr class="hr-session-divider"><td colspan="' +
                String(colspan) +
                '">Submission · ' +
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
          var pill = evidenceStatusPill(it);
          var isArchived = st === 'VERIFIED' || st === 'DECLINED';
          var fitHint = '';
          if ((it.mandatory_needs_review || []).length) {
            if (st === 'VERIFIED') {
              fitHint =
                '<p class="hr-evidence-fit-hint">Also in requirement fit review below — decide whether it satisfies each trust requirement.</p>';
            } else if (st !== 'DECLINED' && st !== 'NOT_SHARED') {
              fitHint =
                '<p class="hr-evidence-fit-hint">Verify the evidence to decide whether it satisfies a trust requirement (requirement fit review).</p>';
            }
          }
          var notSharedHint =
            st === 'NOT_SHARED'
              ? '<p class="hr-evidence-fit-hint">Not shared with HR yet — ask the doctor to share before you can verify evidence.</p>'
              : '';
          var sidForApi =
            merged && it.session_id != null ? String(it.session_id) : fixedSessionId != null ? String(fixedSessionId) : '';
          var btn;
          if (st === 'NOT_SHARED') {
            btn = '<span class="hr-muted">Share required</span>';
          } else if (portfolioRow) {
            btn = '<span class="hr-muted">—</span>';
          } else if (st === 'VERIFIED') {
            btn =
              '<button type="button" class="nhsuk-button nhsuk-button--secondary hr-btn-small" data-unverify="1" data-sid="' +
              esc(sidForApi) +
              '" data-cid="' +
              esc(it.credential_id) +
              '">Unverify</button>';
          } else if (isArchived) {
            btn = '<span class="hr-muted">—</span>';
          } else {
            btn =
              '<div class="hr-evidence-actions">' +
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
          }
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
          var modLabel = esc(it.module_name || it.credential_id || '—');
          var actionable = showSelectCol && isItemActionable(it, merged, portfolioSession);
          var selectCell = showSelectCol
            ? '<td class="hr-table__select">' +
              (actionable
                ? '<input type="checkbox" class="hr-item-select-cb" data-sid="' +
                  esc(sidForApi) +
                  '" data-cid="' +
                  esc(it.credential_id) +
                  '" aria-label="Select ' +
                  modLabel +
                  '">'
                : '') +
              '</td>'
            : '';
          var modCell = moduleEvidenceLinkHtml(it, sidForApi, s);
          parts.push(
            '<tr>' +
              selectCell +
              '<td>' +
              modCell +
              fitHint +
              notSharedHint +
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
        tbody.innerHTML = parts.join('') || '<tr><td colspan="' + String(colspan) + '" class="hr-muted">No items.</td></tr>';
        syncItemsBulkBarCounts();
      }

      async function loadDoctorQueue(doctorUserId) {
        var tbody = document.getElementById('itemsTbody');
        var titleEl = document.getElementById('sessionViewTitle');
        if (titleEl) titleEl.textContent = 'E-learning from this doctor';
        tbody.innerHTML = '<tr><td colspan="5" class="hr-muted">Loading…</td></tr>';
        lastSessionPayload = await apiJson('/api/hr/doctors/' + encodeURIComponent(String(doctorUserId)) + '/queue');
        renderItemsTable(lastSessionPayload, null);
        attachItemsRowHandler(null);
        startSessionViewPoll(null);
      }

      function attachItemsRowHandler(fixedSessionId) {
        lastItemsFixedSessionId = fixedSessionId;
        var sessionView = document.getElementById('sessionView');
        if (!sessionView) return;
        sessionView.onclick = async function (e) {
          var viewCert = e.target && e.target.closest('[data-view-cert="1"]');
          if (viewCert) {
            e.preventDefault();
            var cid = viewCert.getAttribute('data-cid');
            var sid = viewCert.getAttribute('data-sid');
            var it = resolveHrEvidenceItem(lastSessionPayload, cid, sid);
            if (it && it.certificate_base64) openHrCertModal(it);
            return;
          }
          if (_hrSessionActionInFlight) return;
          var fitAccept = e.target && e.target.closest('button[data-fit-accept="1"]');
          var fitReject = e.target && e.target.closest('button[data-fit-reject="1"]');
          if (fitAccept || fitReject) {
            e.preventDefault();
            var fitBtn = fitAccept || fitReject;
            var doctorId = fitBtn.getAttribute('data-doctor-id');
            var fitCid = fitBtn.getAttribute('data-cid');
            var topicName = (fitBtn.getAttribute('data-topic-name') || '').trim();
            var topicIdRaw = fitBtn.getAttribute('data-topic-id');
            if (!doctorId || !fitCid || !topicName) {
              alert('Missing requirement-fit details.');
              return;
            }
            var fitItem = (lastSessionPayload.items || []).find(function (x) {
              return String(x.credential_id) === String(fitCid);
            });
            var moduleLabel = (fitItem && fitItem.module_name) || 'this training';
            var decision = fitAccept ? 'accepted' : 'rejected';
            var confirmMsg = fitAccept
              ? 'Record that "' + moduleLabel + '" satisfies "' + topicName + '"?'
              : 'Record that "' + moduleLabel + '" does not satisfy "' + topicName + '"?';
            if (!confirm(confirmMsg)) return;
            _hrSessionActionInFlight = true;
            fitBtn.disabled = true;
            try {
              var body = {
                topic_name: topicName,
                credential_id: fitCid,
                decision: decision,
              };
              if (topicIdRaw) body.topic_id = Number(topicIdRaw);
              await apiJson(
                '/api/hr/doctors/' + encodeURIComponent(String(doctorId)) + '/mandatory-fit-decisions',
                {
                  method: 'POST',
                  headers: { 'Content-Type': 'application/json' },
                  body: JSON.stringify(body),
                }
              );
              await refreshPayloadAfterAction(fixedSessionId);
              renderMandatoryFitSection(lastSessionPayload);
            } catch (err) {
              alert(err.message || err);
              fitBtn.disabled = false;
            } finally {
              _hrSessionActionInFlight = false;
            }
            return;
          }
          var v = e.target && e.target.closest('button[data-verify="1"]');
          var d = e.target && e.target.closest('button[data-decline="1"]');
          var u = e.target && e.target.closest('button[data-unverify="1"]');
          if (!v && !d && !u) return;
          var cid2 = (v || d || u).getAttribute('data-cid');
          var sidAttr = (v || d || u).getAttribute('data-sid');
          var sessionIdForApi = sidAttr || (fixedSessionId != null ? String(fixedSessionId) : '');
          _hrSessionActionInFlight = true;
          try {
            if (u) {
              if (
                !confirm(
                  'Revert this record to awaiting decision? The doctor will no longer see it as verified by HR at your trust.'
                )
              ) {
                _hrSessionActionInFlight = false;
                return;
              }
              if (!sessionIdForApi) {
                alert('Missing session for this action.');
                _hrSessionActionInFlight = false;
                return;
              }
              u.disabled = true;
              u.textContent = 'Reverting…';
              await apiJson(
                '/api/hr/shares/' +
                  encodeURIComponent(sessionIdForApi) +
                  '/items/' +
                  encodeURIComponent(String(cid2)) +
                  '/unverify',
                { method: 'POST' }
              );
            } else if (v) {
              if (!sessionIdForApi) {
                alert('Missing session for this action.');
                _hrSessionActionInFlight = false;
                return;
              }
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
              if (!sessionIdForApi) {
                alert('Missing session for this action.');
                _hrSessionActionInFlight = false;
                return;
              }
              var reason = (
                prompt('Why are you declining this record? (This will be sent back to the doctor)') || ''
              ).trim();
              if (!reason) {
                _hrSessionActionInFlight = false;
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
            notifyHrInboxChanged();
          } catch (err) {
            alert(err.message || err);
            await refreshPayloadAfterAction(fixedSessionId);
          } finally {
            _hrSessionActionInFlight = false;
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
        if (titleEl) titleEl.textContent = 'Evidence verification';
        tbody.innerHTML = '<tr><td colspan="5" class="hr-muted">Loading…</td></tr>';
        lastSessionPayload = await apiJson('/api/hr/shares/' + encodeURIComponent(String(sessionId)));
        if (titleEl) {
          titleEl.textContent =
            String(lastSessionPayload.share_kind || '').toLowerCase() === 'portfolio'
              ? 'Reference pack (verified elsewhere)'
              : 'Evidence verification';
        }
        renderItemsTable(lastSessionPayload, sessionId);
        attachItemsRowHandler(sessionId);
        startSessionViewPoll(sessionId);
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
          if (HR_PAGE === 'cohorts') {
            show(document.getElementById('searchView'), false);
            show(document.getElementById('searchDoctorView'), false);
            setCohortsGroupsVisible(false);
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
          if (t) t.textContent = 'Add training — ' + (dname || 'Doctor');
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
        var searchDoctorViewId = '';
        var searchDoctorViewName = '';

        function confirmDeleteDoctor(name) {
          var label = (name || '').trim() || 'this doctor';
          return window.confirm(
            'Permanently delete ' + label + '?\n\n' +
            'This removes their DocPass account, all training records, and membership in any groups they belong to. This cannot be undone.'
          );
        }

        async function deleteDoctorAccount(doctorId, doctorName) {
          if (!doctorId) return false;
          if (!confirmDeleteDoctor(doctorName)) return false;
          try {
            await apiJson('/api/hr/doctors/' + encodeURIComponent(String(doctorId)), { method: 'DELETE' });
            return true;
          } catch (err) {
            window.alert(err.message || 'Could not delete doctor.');
            return false;
          }
        }

        function hideSearchDoctorDetailActions() {
          var addTr = document.getElementById('btnSearchDoctorAddTraining');
          if (addTr) addTr.hidden = true;
          var delTr = document.getElementById('btnSearchDoctorDelete');
          if (delTr) delTr.hidden = true;
        }

        function setCohortsGroupsVisible(on) {
          if (HR_PAGE !== 'cohorts') return;
          show(document.getElementById('groupsCard'), on);
        }

        function isCohortsSearchMode() {
          if (HR_PAGE !== 'cohorts') return false;
          var q = qs();
          if (q.get('search') === '1') return true;
          if (q.get('doctor')) return true;
          if ((q.get('q') || '').trim()) return true;
          return false;
        }

        function setCohortsSearchSectionVisible(on) {
          if (HR_PAGE !== 'cohorts') return;
          show(document.getElementById('doctorSearchSection'), on);
        }

        function cohortsSearchHistoryPath(paramObj) {
          var p = new URLSearchParams();
          p.set('search', '1');
          if (paramObj) {
            Object.keys(paramObj).forEach(function (k) {
              if (paramObj[k] != null && String(paramObj[k]).trim() !== '') {
                p.set(k, String(paramObj[k]));
              }
            });
          }
          return '/static/hr/cohorts/?' + p.toString();
        }

        var bulkMod = document.getElementById('bulkModule');
        if (bulkMod) fillHrModuleSelect(bulkMod);

        var bulkWizardStep = 1;
        var bulkRecipientMethod = null;
        var bulkSelectedDoctors = [];
        var BULK_MAX_DOCTORS = 50;
        var _bulkCohortsCache = [];

        function bulkDoctorById(id) {
          return bulkSelectedDoctors.find(function (d) { return Number(d.id) === Number(id); }) || null;
        }

        function renderBulkDoctorList() {
          var list = document.getElementById('bulkDoctorList');
          var empty = document.getElementById('bulkDoctorListEmpty');
          var countEl = document.getElementById('bulkDoctorCount');
          var n = bulkSelectedDoctors.length;
          if (countEl) {
            countEl.textContent = n + ' doctor' + (n === 1 ? '' : 's');
            countEl.classList.toggle('cohort-email-count--empty', n === 0);
          }
          if (empty) empty.hidden = n > 0;
          if (!list) return;
          if (!n) {
            list.innerHTML = '';
            return;
          }
          list.innerHTML = bulkSelectedDoctors.map(function (d) {
            var meta = [];
            if (d.gmc_number) meta.push('GMC ' + esc(d.gmc_number));
            if (d.email) meta.push(esc(d.email));
            return (
              '<div class="cohort-email-row">' +
              '<div class="cohort-email-row__body">' +
              '<span class="cohort-email-row__addr">' + esc(d.name || d.email || 'Doctor') + '</span>' +
              (meta.length ? '<span class="cohort-email-row__sub">' + meta.join(' · ') + '</span>' : '') +
              '</div>' +
              '<button type="button" class="cohort-email-row__remove" data-bulk-remove-doctor="' + esc(String(d.id)) + '" aria-label="Remove ' + esc(d.name || d.email || 'doctor') + '">&times;</button>' +
              '</div>'
            );
          }).join('');
        }

        function addBulkDoctor(doc) {
          if (!doc || doc.id == null) return false;
          if (bulkDoctorById(doc.id)) return false;
          if (bulkSelectedDoctors.length >= BULK_MAX_DOCTORS) {
            setBulkStepError('bulkStepDoctorsError', 'Maximum ' + BULK_MAX_DOCTORS + ' doctors per upload.');
            return false;
          }
          bulkSelectedDoctors.push({
            id: Number(doc.id),
            name: (doc.display_name || doc.email || 'Doctor').trim(),
            email: doc.email || '',
            gmc_number: doc.gmc_number || '',
          });
          setBulkStepError('bulkStepDoctorsError', '');
          renderBulkDoctorList();
          if (bulkWizardStep === 4) updateBulkRecipientsSummary();
          return true;
        }

        function removeBulkDoctor(id) {
          bulkSelectedDoctors = bulkSelectedDoctors.filter(function (d) {
            return Number(d.id) !== Number(id);
          });
          renderBulkDoctorList();
          if (bulkWizardStep === 4) updateBulkRecipientsSummary();
        }

        async function runBulkDoctorSearch() {
          var inp = document.getElementById('bulkDoctorSearchInput');
          var statusEl = document.getElementById('bulkDoctorSearchStatus');
          var resultsEl = document.getElementById('bulkDoctorSearchResults');
          var q = (inp ? inp.value : '').trim();
          if (!q) {
            if (statusEl) statusEl.textContent = 'Enter a name, email, or GMC number.';
            return;
          }
          if (statusEl) statusEl.textContent = 'Searching…';
          if (resultsEl) resultsEl.innerHTML = '';
          try {
            var data = await apiJson('/api/hr/doctors/search?q=' + encodeURIComponent(q) + '&limit=30');
            var results = data.results || [];
            if (statusEl) statusEl.textContent = results.length ? '' : 'No matching doctors found.';
            if (!results.length || !resultsEl) return;
            resultsEl.innerHTML = results.map(function (doc) {
              var name = esc(doc.display_name || doc.email || '—');
              var meta = [];
              if (doc.gmc_number) meta.push('GMC ' + esc(doc.gmc_number));
              if (doc.email) meta.push(esc(doc.email));
              if (doc.current_trust) meta.push(esc(doc.current_trust_display || doc.current_trust));
              var already = bulkDoctorById(doc.id);
              return (
                '<div class="hr-search-result-row">' +
                '<div><div class="hr-search-result-name">' + name + '</div>' +
                (meta.length ? '<div class="hr-search-result-meta">' + meta.join(' &middot; ') + '</div>' : '') +
                '</div>' +
                '<div class="hr-search-result-actions">' +
                (already
                  ? '<span class="hr-muted">Added</span>'
                  : ('<button type="button" class="nhsuk-button hr-btn-small" data-bulk-add-doctor-id="' + esc(String(doc.id)) + '" data-bulk-add-doctor-name="' + esc(doc.display_name || doc.email || '') + '" data-bulk-add-doctor-email="' + esc(doc.email || '') + '" data-bulk-add-doctor-gmc="' + esc(doc.gmc_number || '') + '">Add</button>')) +
                '</div></div>'
              );
            }).join('');
          } catch (err) {
            if (statusEl) statusEl.textContent = err.message || 'Search failed.';
          }
        }

        function getSelectedBulkCohortIds() {
          var list = document.getElementById('bulkCohortList');
          if (!list) return [];
          return Array.prototype.slice.call(
            list.querySelectorAll('input[type="checkbox"][data-bulk-cohort-id]:checked')
          ).map(function (inp) { return parseInt(inp.getAttribute('data-bulk-cohort-id'), 10); })
            .filter(function (id) { return !isNaN(id); });
        }

        function bulkCohortById(id) {
          return _bulkCohortsCache.find(function (c) { return Number(c.id) === Number(id); }) || null;
        }

        function renderBulkCohortList(cohorts) {
          var list = document.getElementById('bulkCohortList');
          if (!list) return;
          _bulkCohortsCache = cohorts || [];
          if (!_bulkCohortsCache.length) {
            list.innerHTML = '<p class="hr-bulk-cohort-list__empty">No groups yet. Create one from Groups first.</p>';
            return;
          }
          list.innerHTML = _bulkCohortsCache.map(function (c) {
            var n = (c.name || 'Group').trim();
            var cnt = c.member_count != null ? c.member_count : 0;
            var checked = c.is_default || String(n).toLowerCase() === 'all doctors' || String(n).toLowerCase() === 'ad-hoc' ? ' checked' : '';
            return (
              '<label class="hr-bulk-cohort-option">' +
              '<input type="checkbox" data-bulk-cohort-id="' + esc(String(c.id)) + '"' + checked + '>' +
              '<span><strong>' + esc(n) + '</strong>' +
              '<span class="hr-bulk-cohort-option__meta">' + cnt + ' member' + (cnt === 1 ? '' : 's') + '</span></span>' +
              '</label>'
            );
          }).join('');
        }

        function clearBulkCohortSelection() {
          var list = document.getElementById('bulkCohortList');
          if (!list) return;
          list.querySelectorAll('input[type="checkbox"][data-bulk-cohort-id]').forEach(function (inp) {
            inp.checked = false;
          });
        }

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
            var ids = getSelectedBulkCohortIds();
            if (!ids.length) {
              el.textContent = '';
              return;
            }
            var names = ids.map(function (id) {
              var c = bulkCohortById(id);
              return c ? (c.name || 'Group').trim() : ('Group ' + id);
            });
            var label = names.length === 1
              ? 'group “' + names[0] + '”'
              : ids.length + ' groups (“' + names.slice(0, 3).join('”, “') + (names.length > 3 ? '”, …' : '') + '”)';
            el.textContent = 'Recipients: ' + label + '. Duplicates across groups are only issued once.';
          } else if (bulkRecipientMethod === 'roster') {
            var r = document.getElementById('bulkRoster');
            var name = r && r.files && r.files[0] ? r.files[0].name : '';
            el.textContent = name ? 'Recipients: roster file “' + name + '”.' : 'Recipients: roster file.';
          } else if (bulkRecipientMethod === 'search') {
            if (!bulkSelectedDoctors.length) {
              el.textContent = '';
              return;
            }
            var docNames = bulkSelectedDoctors.map(function (d) { return d.name; });
            var docLabel = docNames.length === 1
              ? '“' + docNames[0] + '”'
              : docNames.length + ' doctors (“' + docNames.slice(0, 3).join('”, “') + (docNames.length > 3 ? '”, …' : '') + '”)';
            el.textContent = 'Recipients: ' + docLabel + '.';
          } else {
            el.textContent = '';
          }
        }

        function bulkStepTwoLabel() {
          if (bulkRecipientMethod === 'cohort') return 'Step 2 of 4 — Choose groups';
          if (bulkRecipientMethod === 'search') return 'Step 2 of 4 — Choose doctors';
          return 'Step 2 of 4 — Upload roster';
        }

        function setBulkWizardStep(step) {
          bulkWizardStep = step;
          var label = document.getElementById('bulkWizardStepLabel');
          if (label) {
            if (step === 1) label.textContent = 'Step 1 of 4 — Who receives this?';
            else if (step === 2) label.textContent = bulkStepTwoLabel();
            else if (step === 3) label.textContent = 'Step 3 of 4 — Class evidence';
            else label.textContent = 'Step 4 of 4 — Training details';
          }
          var stepMethod = document.getElementById('bulkStepMethod');
          var stepDoctors = document.getElementById('bulkStepDoctors');
          var stepCohort = document.getElementById('bulkStepCohort');
          var stepRoster = document.getElementById('bulkStepRoster');
          var stepEvidence = document.getElementById('bulkStepEvidence');
          var stepDetails = document.getElementById('bulkStepDetails');
          if (stepMethod) stepMethod.hidden = step !== 1;
          if (stepDoctors) stepDoctors.hidden = !(step === 2 && bulkRecipientMethod === 'search');
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
          bulkSelectedDoctors = [];
          clearBulkCohortSelection();
          var defaultCohort = _bulkCohortsCache.find(function (c) {
            return c.is_default || String(c.name || '').trim().toLowerCase() === 'all doctors'
              || String(c.name || '').trim().toLowerCase() === 'ad-hoc';
          });
          if (defaultCohort && defaultCohort.id != null) {
            var inp = document.querySelector(
              'input[data-bulk-cohort-id="' + String(defaultCohort.id) + '"]'
            );
            if (inp) inp.checked = true;
          }
          var rosterEl = document.getElementById('bulkRoster');
          var evidenceEl = document.getElementById('bulkEvidence');
          if (rosterEl) rosterEl.value = '';
          if (evidenceEl) evidenceEl.value = '';
          var rn = document.getElementById('bulkRosterName');
          var en = document.getElementById('bulkEvidenceName');
          if (rn) rn.textContent = 'No file chosen';
          if (en) en.textContent = 'No file chosen';
          var bulkSearchInp = document.getElementById('bulkDoctorSearchInput');
          var bulkSearchResults = document.getElementById('bulkDoctorSearchResults');
          var bulkSearchStatus = document.getElementById('bulkDoctorSearchStatus');
          if (bulkSearchInp) bulkSearchInp.value = '';
          if (bulkSearchResults) bulkSearchResults.innerHTML = '';
          if (bulkSearchStatus) bulkSearchStatus.textContent = '';
          renderBulkDoctorList();
          setBulkStepError('bulkStepCohortError', '');
          setBulkStepError('bulkStepDoctorsError', '');
          setBulkStepError('bulkStepRosterError', '');
          setBulkStepError('bulkStepEvidenceError', '');
          syncBulkRosterPicker();
          syncBulkEvidencePicker();
          setBulkWizardStep(1);
        }

        async function fillBulkCohortSelect() {
          if (HR_PAGE !== 'bulk') return;
          try {
            var data = await apiJson('/api/hr/cohorts');
            renderBulkCohortList(data.cohorts || []);
          } catch (e) {
            renderBulkCohortList([]);
          }
        }

        if (HR_PAGE === 'bulk') {
          document.querySelectorAll('[data-bulk-method]').forEach(function (btn) {
            btn.addEventListener('click', function () {
              bulkRecipientMethod = btn.getAttribute('data-bulk-method');
              setBulkWizardStep(2);
              if (bulkRecipientMethod === 'cohort') {
                var list = document.getElementById('bulkCohortList');
                if (list) list.focus();
              } else if (bulkRecipientMethod === 'search') {
                var searchInp = document.getElementById('bulkDoctorSearchInput');
                if (searchInp) searchInp.focus();
              } else {
                syncBulkRosterPicker();
                var r = document.getElementById('bulkRoster');
                if (r) r.focus();
              }
            });
          });

          var bulkDoctorSearchBtn = document.getElementById('bulkDoctorSearchBtn');
          if (bulkDoctorSearchBtn) {
            bulkDoctorSearchBtn.addEventListener('click', function () { void runBulkDoctorSearch(); });
          }
          wireHrDoctorSearchSuggest({
            inputId: 'bulkDoctorSearchInput',
            listId: 'bulkDoctorSearchSuggestList',
            wrapId: 'bulkDoctorSearchAcWrap',
            onSelect: function (doc) {
              var inp = document.getElementById('bulkDoctorSearchInput');
              if (inp) inp.value = '';
              addBulkDoctor(doc);
            },
            onEnter: function () { void runBulkDoctorSearch(); },
          });
          var bulkDoctorSearchResults = document.getElementById('bulkDoctorSearchResults');
          if (bulkDoctorSearchResults) {
            bulkDoctorSearchResults.addEventListener('click', function (e) {
              var addBtn = e.target && e.target.closest('[data-bulk-add-doctor-id]');
              if (!addBtn) return;
              var added = addBulkDoctor({
                id: addBtn.getAttribute('data-bulk-add-doctor-id'),
                display_name: addBtn.getAttribute('data-bulk-add-doctor-name'),
                email: addBtn.getAttribute('data-bulk-add-doctor-email'),
                gmc_number: addBtn.getAttribute('data-bulk-add-doctor-gmc'),
              });
              if (added) {
                addBtn.outerHTML = '<span class="hr-muted">Added</span>';
              }
            });
          }
          var bulkDoctorList = document.getElementById('bulkDoctorList');
          if (bulkDoctorList) {
            bulkDoctorList.addEventListener('click', function (e) {
              var rm = e.target && e.target.closest('[data-bulk-remove-doctor]');
              if (!rm) return;
              removeBulkDoctor(rm.getAttribute('data-bulk-remove-doctor'));
            });
          }

          var bulkNextDoctors = document.getElementById('bulkNextDoctors');
          if (bulkNextDoctors) {
            bulkNextDoctors.addEventListener('click', function () {
              if (!bulkSelectedDoctors.length) {
                setBulkStepError('bulkStepDoctorsError', 'Add at least one doctor to continue.');
                var searchInp = document.getElementById('bulkDoctorSearchInput');
                if (searchInp) searchInp.focus();
                return;
              }
              setBulkStepError('bulkStepDoctorsError', '');
              setBulkWizardStep(3);
              var ev = document.getElementById('bulkEvidence');
              if (ev) ev.focus();
            });
          }
          var bulkBackDoctors = document.getElementById('bulkBackDoctors');
          if (bulkBackDoctors) bulkBackDoctors.addEventListener('click', function () { setBulkWizardStep(1); });

          var bulkCohortListEl = document.getElementById('bulkCohortList');
          if (bulkCohortListEl) {
            bulkCohortListEl.addEventListener('change', function () {
              setBulkStepError('bulkStepCohortError', '');
              if (bulkWizardStep === 4) updateBulkRecipientsSummary();
            });
          }

          var bulkNextCohort = document.getElementById('bulkNextCohort');
          if (bulkNextCohort) {
            bulkNextCohort.addEventListener('click', function () {
              var ids = getSelectedBulkCohortIds();
              if (!ids.length) {
                setBulkStepError('bulkStepCohortError', 'Select at least one group to continue.');
                var list = document.getElementById('bulkCohortList');
                if (list) list.focus();
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
              setBulkStepError('bulkStepEvidenceError', '');
              setBulkWizardStep(4);
              var mod = document.getElementById('bulkModule');
              if (mod) mod.focus();
            });
          }

          var bulkBackEvidence = document.getElementById('bulkBackEvidence');
          if (bulkBackEvidence) {
            bulkBackEvidence.addEventListener('click', function () {
              setBulkWizardStep(2);
              if (bulkRecipientMethod === 'cohort') {
                var listBack = document.getElementById('bulkCohortList');
                if (listBack) listBack.focus();
              } else if (bulkRecipientMethod === 'search') {
                var searchBack = document.getElementById('bulkDoctorSearchInput');
                if (searchBack) searchBack.focus();
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
          sdTbody.addEventListener('click', async function (e) {
            var unBtn = e.target && e.target.closest('button[data-search-unverify="1"]');
            if (unBtn) {
              e.preventDefault();
              var cidU = unBtn.getAttribute('data-cid');
              if (!searchDoctorViewId || !cidU) return;
              if (
                !confirm(
                  'Remove HR verification for this record? The doctor will no longer see it as verified by HR at your trust.'
                )
              ) {
                return;
              }
              unBtn.disabled = true;
              unBtn.textContent = 'Reverting…';
              try {
                await apiJson(
                  '/api/hr/doctors/' +
                    encodeURIComponent(searchDoctorViewId) +
                    '/credentials/' +
                    encodeURIComponent(String(cidU)) +
                    '/unverify',
                  { method: 'POST' }
                );
                var titleEl = document.getElementById('searchDoctorTitle');
                await openSearchDoctorView(
                  searchDoctorViewId,
                  titleEl ? titleEl.textContent.replace(/^Verified training —\s*/, '') : 'Doctor'
                );
              } catch (err) {
                alert(err.message || err);
                unBtn.disabled = false;
                unBtn.textContent = 'Unverify';
              }
              return;
            }
            var btn = e.target && e.target.closest('[data-view-docs-cid]');
            if (!btn) return;
            e.preventDefault();
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
              return;
            }
            var delBtn = e.target && e.target.closest('button[data-delete-doctor-id]');
            if (delBtn) {
              e.preventDefault();
              var delId = delBtn.getAttribute('data-delete-doctor-id');
              var delName = delBtn.getAttribute('data-delete-doctor-name') || '';
              var ok = await deleteDoctorAccount(delId, delName);
              if (!ok) return;
              var row = delBtn.closest('.hr-search-result-row');
              if (row) row.remove();
              var statusEl = document.getElementById('searchStatus');
              if (statusEl) statusEl.textContent = 'Doctor deleted.';
              if (searchDoctorViewId && String(searchDoctorViewId) === String(delId)) {
                searchDoctorViewId = '';
                searchDoctorViewName = '';
                hideSearchDoctorDetailActions();
                show(document.getElementById('searchDoctorView'), false);
                show(document.getElementById('searchView'), true);
                if (HR_PAGE === 'search' || HR_PAGE === 'cohorts') {
                  try {
                    window.history.replaceState({}, '', HR_PAGE === 'cohorts'
                      ? cohortsSearchHistoryPath()
                      : '/static/hr/cohorts/?search=1');
                  } catch (eHistDel) {}
                }
              }
            }
          });
        }

        var btnSearchDoctorDelete = document.getElementById('btnSearchDoctorDelete');
        if (btnSearchDoctorDelete) {
          btnSearchDoctorDelete.addEventListener('click', async function () {
            if (!searchDoctorViewId) return;
            var ok = await deleteDoctorAccount(searchDoctorViewId, searchDoctorViewName);
            if (!ok) return;
            searchDoctorViewId = '';
            searchDoctorViewName = '';
            hideSearchDoctorDetailActions();
            show(document.getElementById('searchDoctorView'), false);
            show(document.getElementById('searchView'), true);
            setCohortsGroupsVisible(true);
            var statusEl = document.getElementById('searchStatus');
            if (statusEl) statusEl.textContent = 'Doctor deleted.';
            if (HR_PAGE === 'search' || HR_PAGE === 'cohorts') {
              try {
                window.history.replaceState({}, '', HR_PAGE === 'cohorts'
                  ? cohortsSearchHistoryPath()
                  : '/static/hr/cohorts/?search=1');
              } catch (eHistDel2) {}
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
            var selectedCohortIds = bulkRecipientMethod === 'cohort' ? getSelectedBulkCohortIds() : [];
            var hasCohorts = selectedCohortIds.length > 0;
            var hasRoster = bulkRecipientMethod === 'roster' && rosterEl && rosterEl.files && rosterEl.files[0];
            var hasDoctors = bulkRecipientMethod === 'search' && bulkSelectedDoctors.length > 0;
            if (!hasCohorts && !hasRoster && !hasDoctors) {
              setBulkStatusMessage('Complete the recipient steps: search for doctors, select a group, or upload a roster file.', 'error');
              setBulkWizardStep(2);
              return;
            }
            bulkSubmitBusy = true;
            btnBulkSubmit.disabled = true;
            var bulkVizEl = document.getElementById('bulkProvisionResult');
            var bulkSt = document.getElementById('bulkStatus');
            if (bulkSt) bulkSt.hidden = true;
            if (batchViz()) batchViz().clear(bulkVizEl);
            var bulkStartMsg = 'Preparing bulk training issue…';
            if (hasCohorts) {
              if (selectedCohortIds.length === 1) {
                var one = bulkCohortById(selectedCohortIds[0]);
                var oneName = one ? (one.name || 'Group').trim() : ('Group ' + selectedCohortIds[0]);
                bulkStartMsg = 'Loading group “' + oneName + '”…';
              } else {
                bulkStartMsg = 'Loading ' + selectedCohortIds.length + ' groups…';
              }
            } else if (hasRoster) {
              bulkStartMsg = 'Uploading roster file…';
            } else if (hasDoctors) {
              bulkStartMsg = bulkSelectedDoctors.length === 1
                ? 'Issuing training for ' + bulkSelectedDoctors[0].name + '…'
                : 'Issuing training for ' + bulkSelectedDoctors.length + ' doctors…';
            }
            if (batchViz()) batchViz().showLoading(bulkVizEl, bulkStartMsg);
            if (wrap) wrap.hidden = true;
            if (tbody) tbody.innerHTML = '';
            try {
              var fd = new FormData();
              if (hasCohorts) {
                fd.append('cohort_ids', JSON.stringify(selectedCohortIds));
              } else if (hasDoctors) {
                fd.append('doctor_user_ids', JSON.stringify(bulkSelectedDoctors.map(function (d) { return d.id; })));
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
            hideSearchDoctorDetailActions();
            show(document.getElementById('searchDoctorView'), false);
            show(document.getElementById('searchView'), true);
            setCohortsGroupsVisible(true);
            if (HR_PAGE === 'search' || HR_PAGE === 'cohorts') {
              try {
                window.history.replaceState({}, '', HR_PAGE === 'cohorts'
                  ? cohortsSearchHistoryPath()
                  : '/static/hr/cohorts/?search=1');
              } catch (eHist2) {}
            }
          });
        }

        async function runDoctorSearch(opts) {
          opts = opts || {};
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
            if (statusEl) statusEl.textContent = results.length ? '' : 'No matching doctors found.';
            if (!results.length) { if (resultsEl) resultsEl.innerHTML = ''; return; }
            if (results.length === 1 && opts.autoOpenSingle) {
              await openSearchDoctorView(results[0].id, results[0].display_name || results[0].email || '');
              return;
            }
            if (resultsEl) {
              resultsEl.innerHTML = results.map(function (doc) {
                var name = esc(doc.display_name || doc.email || '—');
                var meta = [];
                if (doc.gmc_number) meta.push('GMC ' + esc(doc.gmc_number));
                if (doc.email) meta.push(esc(doc.email));
                if (doc.current_trust) meta.push(esc(doc.current_trust_display || doc.current_trust));
                return (
                  '<div class="hr-search-result-row">' +
                  '<div><div class="hr-search-result-name">' + name + '</div>' +
                  (meta.length ? '<div class="hr-search-result-meta">' + meta.join(' &middot; ') + '</div>' : '') +
                  '</div>' +
                  '<div class="hr-search-result-actions">' +
                  '<button type="button" class="nhsuk-button hr-btn-small" data-search-doctor-id="' + esc(String(doc.id)) + '" data-search-doctor-name="' + esc(doc.display_name || doc.email || '') + '">View training</button>' +
                  '<button type="button" class="nhsuk-button nhsuk-button--secondary hr-btn-small" data-add-doctor-id="' + esc(String(doc.id)) + '" data-add-doctor-name="' + esc(doc.display_name || doc.email || '') + '">Add training</button>' +
                  '<a class="nhsuk-button nhsuk-button--secondary hr-btn-small" href="/static/hr/messages/?doctor=' + encodeURIComponent(String(doc.id)) + '">Message</a>' +
                  '<button type="button" class="nhsuk-button nhsuk-button--secondary hr-btn-small cohort-delete-btn" data-delete-doctor-id="' + esc(String(doc.id)) + '" data-delete-doctor-name="' + esc(doc.display_name || doc.email || '') + '">Delete</button>' +
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
          searchDoctorViewId = String(doctorId || '');
          searchDoctorViewName = doctorName || '';
          if (HR_PAGE === 'search' || HR_PAGE === 'cohorts') {
            try {
              var histParams = { doctor: String(doctorId) };
              if (doctorName) histParams.name = doctorName;
              window.history.replaceState({}, '', HR_PAGE === 'cohorts'
                ? cohortsSearchHistoryPath(histParams)
                : '/static/hr/cohorts/?search=1&doctor=' + encodeURIComponent(String(doctorId)));
            } catch (eHist) {}
          }
          setCohortsSearchSectionVisible(true);
          show(document.getElementById('searchView'), false);
          show(document.getElementById('searchDoctorView'), true);
          setCohortsGroupsVisible(false);
          var titleEl = document.getElementById('searchDoctorTitle');
          if (titleEl) titleEl.textContent = 'Verified training — ' + (doctorName || 'Doctor');
          var addTr = document.getElementById('btnSearchDoctorAddTraining');
          if (addTr) {
            addTr.hidden = false;
            addTr.setAttribute('data-doctor-id', String(doctorId));
            addTr.setAttribute('data-doctor-name', doctorName || '');
          }
          var delTr = document.getElementById('btnSearchDoctorDelete');
          if (delTr) {
            delTr.hidden = false;
            delTr.setAttribute('data-doctor-id', String(doctorId));
            delTr.setAttribute('data-doctor-name', doctorName || '');
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
              if (tbody) tbody.innerHTML = '<tr><td colspan="4" class="hr-muted">No verified records for this doctor yet.</td></tr>';
              return;
            }
            if (tbody) {
              tbody.innerHTML = items.map(function (it) {
                var namePlain = esc(it.module_name || it.credential_id || '—');
                var nameCell = it.certificate_base64
                  ? ('<a href="#" class="hr-module-name-btn" data-view-docs-cid="' +
                    esc(String(it.credential_id || '')) +
                    '" title="View evidence for this record">' +
                    namePlain +
                    '</a>')
                  : namePlain;
                var expiry = it.expiry_date ? esc(String(it.expiry_date).slice(0, 10)) : '—';
                var issuer = it.issuing_trust_name ? '<div style="font-size:0.8125rem;color:var(--nhsuk-secondary-text);">Issuing: ' + esc(it.issuing_trust_name) + '</div>' : '';
                var verifiedAt = it.verified_by_trust_name ? '<div style="font-size:0.8125rem;color:var(--nhsuk-secondary-text);">HR verified at: ' + esc(it.verified_by_trust_name) + '</div>' : '';
                var evCell = it.certificate_base64
                  ? ('<button type="button" class="nhsuk-button nhsuk-button--secondary hr-btn-small" data-view-docs-cid="' +
                    esc(String(it.credential_id || '')) + '">View</button>')
                  : '—';
                var portfolioRow = String(it.session_share_kind || '').toLowerCase() === 'portfolio';
                var actionCell = portfolioRow
                  ? '<span class="hr-muted">—</span>'
                  : (
                    '<button type="button" class="nhsuk-button nhsuk-button--secondary hr-btn-small" data-search-unverify="1" data-cid="' +
                    esc(String(it.credential_id || '')) +
                    '">Unverify</button>'
                  );
                return (
                  '<tr>' +
                  '<td>' + nameCell + issuer + '</td>' +
                  '<td>' + expiry + '</td>' +
                  '<td><span class="hr-pill hr-pill--verified">Verified</span>' + verifiedAt + '</td>' +
                  '<td>' + evCell + ' ' + actionCell + '</td>' +
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
        wireHrDoctorSearchSuggest({
          inputId: 'doctorSearchInput',
          listId: 'doctorSearchSuggestList',
          wrapId: 'doctorSearchAcWrap',
          onSelect: function (doc) {
            var inp = document.getElementById('doctorSearchInput');
            if (inp) inp.value = doc.display_name || doc.email || '';
            void openSearchDoctorView(doc.id, doc.display_name || doc.email || '');
          },
          onEnter: function () { void runDoctorSearch(); },
        });

        if (HR_PAGE === 'inbox') {
          var legQ = qs();
          if (legQ.get('search')) {
            var uLeg = new URL(window.location.href);
            uLeg.pathname = '/static/hr/cohorts/';
            uLeg.searchParams.set('search', '1');
            window.location.replace(uLeg.pathname + uLeg.search + uLeg.hash);
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
            await openSearchDoctorView(doctorId, qs().get('name') || 'Doctor');
          } else {
            var qParam = (qs().get('q') || '').trim();
            if (qParam) {
              var inp = document.getElementById('doctorSearchInput');
              if (inp) inp.value = qParam;
              await runDoctorSearch({ autoOpenSingle: true });
            }
          }
          return;
        }

        if (HR_PAGE === 'bulk') {
          show(document.getElementById('bulkView'), true);
          await fillHrIssuingTrustFieldsIfEmpty();
          return;
        }

        if (HR_PAGE === 'cohorts') {
          var searchMode = isCohortsSearchMode();
          setCohortsSearchSectionVisible(searchMode);
          show(document.getElementById('searchView'), searchMode);
          show(document.getElementById('searchDoctorView'), false);
          setCohortsGroupsVisible(true);
          if (typeof window.syncCohortsPageHead === 'function') window.syncCohortsPageHead();
          if (doctorId) {
            await openSearchDoctorView(doctorId, qs().get('name') || 'Doctor');
          } else {
            var qParamCohort = (qs().get('q') || '').trim();
            if (qParamCohort) {
              var inpCohort = document.getElementById('doctorSearchInput');
              if (inpCohort) inpCohort.value = qParamCohort;
              await runDoctorSearch({ autoOpenSingle: true });
            }
          }
          return;
        }

        /* HR_PAGE === 'inbox' */
        var inboxModSel = document.getElementById('inboxFilterModule');
        var inboxStSel = document.getElementById('inboxFilterStatus');
        if (inboxModSel) {
          inboxModSel.addEventListener('change', function () {
            inboxFilterModule = this.value || '';
            rerenderInboxFromCache();
          });
        }
        if (inboxStSel) {
          inboxStSel.addEventListener('change', function () {
            inboxFilterStatus = this.value || '';
            rerenderInboxFromCache();
          });
        }
        var itemsModSel = document.getElementById('itemsFilterModule');
        var itemsStSel = document.getElementById('itemsFilterStatus');
        if (itemsModSel) {
          itemsModSel.addEventListener('change', function () {
            itemsFilterModule = this.value || '';
            if (lastSessionPayload) {
              var sid = qs().get('session');
              renderItemsTable(lastSessionPayload, sid || null);
            }
          });
        }
        if (itemsStSel) {
          itemsStSel.addEventListener('change', function () {
            itemsFilterStatus = this.value || '';
            if (lastSessionPayload) {
              var sid2 = qs().get('session');
              renderItemsTable(lastSessionPayload, sid2 || null);
            }
          });
        }
        wireItemsBulkHandlers();

        if (doctorId) {
          stopInboxPoll();
          show(document.getElementById('sessionView'), true);
          show(document.getElementById('inboxView'), false);
          itemsTab = loadStoredTab(LS_ITEMS_TAB, 'new');
          setSegmentTab('sessionView', itemsTab);
          wireTabs('sessionView', LS_ITEMS_TAB, function (tab) {
            itemsTab = tab === 'archived' ? 'archived' : 'new';
            if (lastSessionPayload) renderItemsTable(lastSessionPayload, null);
          });
          await loadDoctorQueue(doctorId);
        } else if (sessionId) {
          stopInboxPoll();
          show(document.getElementById('sessionView'), true);
          show(document.getElementById('inboxView'), false);
          itemsTab = loadStoredTab(LS_ITEMS_TAB, 'new');
          setSegmentTab('sessionView', itemsTab);
          wireTabs('sessionView', LS_ITEMS_TAB, function (tab) {
            itemsTab = tab === 'archived' ? 'archived' : 'new';
            if (lastSessionPayload) renderItemsTable(lastSessionPayload, sessionId);
          });
          await loadSession(sessionId);
        } else {
          stopSessionViewPoll();
          show(document.getElementById('inboxView'), true);
          show(document.getElementById('sessionView'), false);
          inboxTab = loadStoredTab(LS_INBOX_TAB, 'new');
          setSegmentTab('inboxView', inboxTab);
          wireTabs('inboxView', LS_INBOX_TAB, async function (tab) {
            inboxTab = tab === 'archived' ? 'archived' : 'new';
            await loadInbox();
          });
          await loadInbox();
          startInboxPoll();
        }
      })();
})();
