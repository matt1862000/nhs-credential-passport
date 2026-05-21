/**
 * Shared loading skeleton + animated batch result summary (ESR import, HR cohorts, bulk training).
 */
(function (w) {
  function escapeHtml(s) {
    var d = document.createElement('div');
    d.textContent = s == null ? '' : String(s);
    return d.innerHTML;
  }

  function reducedMotion() {
    return !!(w.matchMedia && w.matchMedia('(prefers-reduced-motion: reduce)').matches);
  }

  function clear(el) {
    if (el) el.innerHTML = '';
  }

  /** Scroll feedback boxes into view after green submit buttons (often below the fold). */
  function scrollToFeedback(el) {
    if (!el) return;
    var target = el.closest('.hr-provision-viz-wrap') || el;
    requestAnimationFrame(function () {
      var rect = target.getBoundingClientRect();
      var margin = 24;
      var vh = window.innerHeight || document.documentElement.clientHeight;
      var belowFold = rect.top > vh * 0.45;
      var clipped = rect.bottom > vh - margin;
      if (!belowFold && !clipped) return;
      target.scrollIntoView({
        behavior: reducedMotion() ? 'auto' : 'smooth',
        block: 'start',
      });
    });
  }

  function showLoading(el, message) {
    if (!el) return;
    el.innerHTML =
      '<div class="csv-import-loader" role="status" aria-live="polite">' +
      '<div class="csv-import-loader__track" aria-hidden="true">' +
      '<span class="csv-import-loader__row"></span><span class="csv-import-loader__row"></span>' +
      '<span class="csv-import-loader__row"></span><span class="csv-import-loader__row"></span>' +
      '<span class="csv-import-loader__row"></span></div>' +
      '<p class="csv-import-loader__text" data-loader-text>' + escapeHtml(message || 'Working…') + '</p>' +
      '<div class="csv-import-loader__progress" data-loader-progress hidden>' +
      '<div class="csv-import-loader__progress-bar" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow="0">' +
      '<span class="csv-import-loader__progress-fill" data-loader-progress-fill style="width:0%"></span></div>' +
      '<p class="csv-import-loader__progress-label" data-loader-progress-label></p></div></div>';
    scrollToFeedback(el);
  }

  function updateLoadingProgress(el, opts) {
    if (!el) return;
    opts = opts || {};
    var root = el.querySelector('.csv-import-loader');
    if (!root) {
      showLoading(el, opts.message || 'Working…');
      root = el.querySelector('.csv-import-loader');
    }
    if (!root) return;
    var textEl = root.querySelector('[data-loader-text]');
    if (textEl && opts.message) textEl.textContent = opts.message;
    var wrap = root.querySelector('[data-loader-progress]');
    var fill = root.querySelector('[data-loader-progress-fill]');
    var bar = root.querySelector('.csv-import-loader__progress-bar');
    var label = root.querySelector('[data-loader-progress-label]');
    var total = Math.max(0, Number(opts.total || 0));
    var current = Math.max(0, Number(opts.current || 0));
    if (wrap && total > 0 && opts.showBar !== false) {
      wrap.hidden = false;
      var pct = Math.min(100, Math.round((current / total) * 100));
      if (fill) fill.style.width = pct + '%';
      if (bar) {
        bar.setAttribute('aria-valuenow', String(pct));
        bar.setAttribute('aria-valuemax', '100');
      }
      if (label) {
        label.textContent = current + ' of ' + total;
      }
    } else if (wrap && opts.showBar === false) {
      wrap.hidden = true;
    }
    scrollToFeedback(el);
  }

  var PROGRESS_BAR_PHASES = {
    validate: true,
    wallet: true,
    issue: true,
    provision: true,
    send: true,
    welcome: true,
    import: true,
  };

  function progressShowsBar(phase) {
    return !!(phase && PROGRESS_BAR_PHASES[phase]);
  }

  async function readNdjsonStream(res, el, onProgress) {
    var ct = (res.headers.get('content-type') || '').toLowerCase();
    if (!res.ok) {
      var errText = await res.text();
      var errData = null;
      try {
        errData = errText ? JSON.parse(errText) : null;
      } catch (e1) {
        errData = null;
      }
      var detail = errData && errData.detail;
      throw new Error(typeof detail === 'string' ? detail : errText || res.statusText || 'Request failed');
    }
    if (ct.indexOf('ndjson') < 0 && ct.indexOf('json') >= 0) {
      return res.json();
    }
    if (!res.body || !res.body.getReader) {
      throw new Error('Progress streaming is not supported in this browser.');
    }
    var reader = res.body.getReader();
    var decoder = new TextDecoder();
    var buf = '';
    var result = null;
    function handleEvent(ev) {
      if (!ev || !ev.event) return;
      if (ev.event === 'progress') {
        if (onProgress) onProgress(ev);
        if (el) {
          updateLoadingProgress(el, {
            message: ev.message,
            current: ev.current,
            total: ev.total,
            showBar: ev.total > 0 && progressShowsBar(ev.phase),
          });
        }
      } else if (ev.event === 'complete') {
        result = ev.data;
      } else if (ev.event === 'error') {
        throw new Error(ev.message || 'Request failed.');
      }
    }
    while (true) {
      var chunk = await reader.read();
      if (chunk.done) break;
      buf += decoder.decode(chunk.value, { stream: true });
      var parts = buf.split('\n');
      buf = parts.pop() || '';
      parts.forEach(function (line) {
        line = line.trim();
        if (!line) return;
        handleEvent(JSON.parse(line));
      });
    }
    if (buf.trim()) {
      handleEvent(JSON.parse(buf.trim()));
    }
    if (!result) {
      throw new Error('Request finished without a result.');
    }
    return result;
  }

  /**
   * POST with stream=true (JSON body or FormData). Reads application/x-ndjson progress lines.
   */
  async function postNdjsonStream(url, options, el, onProgress) {
    options = options || {};
    var init = { method: options.method || 'POST', credentials: 'include' };
    if (options.json != null) {
      var payload = Object.assign({}, options.json);
      payload.stream = true;
      init.headers = Object.assign({}, options.headers || {}, {
        'Content-Type': 'application/json',
      });
      init.body = JSON.stringify(payload);
    } else if (options.formData) {
      options.formData.append('stream', '1');
      init.body = options.formData;
    } else {
      throw new Error('postNdjsonStream requires json or formData');
    }
    var res = await fetch(options.fetchUrl || url, init);
    return readNdjsonStream(res, el, onProgress);
  }

  async function postBulkTrainingStream(url, formData, el, onProgress) {
    return postNdjsonStream(url, { formData: formData }, el, onProgress);
  }

  function animateStatNumbers(root) {
    if (!root || reducedMotion()) return;
    root.querySelectorAll('[data-count]').forEach(function (node) {
      var target = parseInt(node.getAttribute('data-count'), 10) || 0;
      var start = performance.now();
      var duration = 650;
      function tick(now) {
        var t = Math.min(1, (now - start) / duration);
        var eased = 1 - Math.pow(1 - t, 3);
        node.textContent = String(Math.round(target * eased));
        if (t < 1) requestAnimationFrame(tick);
      }
      requestAnimationFrame(tick);
    });
  }

  function pct(count, denom) {
    return Math.round(((count || 0) / (denom || 1)) * 1000) / 10;
  }

  function sumCounts(segments) {
    var t = 0;
    (segments || []).forEach(function (s) { t += s.count || 0; });
    return t;
  }

  function activateViz(el) {
    var viz = el && el.querySelector('.csv-import-viz');
    if (!viz) return;
    requestAnimationFrame(function () {
      viz.classList.add('is-ready');
      animateStatNumbers(viz);
    });
  }

  /**
   * @param {HTMLElement} el
   * @param {Object} opts
   * @param {string} [opts.fatalError]
   * @param {number} [opts.total]
   * @param {number} [opts.denom]
   * @param {string} [opts.barTitle]
   * @param {Array<{count:number, variant:'valid'|'skipped'|'invalid'}>} opts.segments
   * @param {Array<{count:number, label:string, variant?:string}>} opts.statItems
   * @param {string} [opts.successHtml]
   * @param {Array<string>} [opts.notesHtml]
   * @param {Array<string>} [opts.errors]
   * @param {string} [opts.detailsHtml]
   */
  function render(el, opts) {
    opts = opts || {};
    if (!el) return;
    if (opts.fatalError) {
      el.innerHTML = '<p class="batch-viz-fatal">' + escapeHtml(opts.fatalError) + '</p>';
      scrollToFeedback(el);
      return;
    }
    var segments = (opts.segments || []).filter(function (s) { return (s.count || 0) > 0; });
    var statItems = opts.statItems || [];
    var total = opts.total != null ? opts.total : sumCounts(segments);
    var denom = opts.denom || total || sumCounts(segments) || 1;
    var wValid = 0;
    var wSkipped = 0;
    var wInvalid = 0;
    segments.forEach(function (seg) {
      var width = pct(seg.count, denom);
      if (seg.variant === 'valid') wValid = width;
      else if (seg.variant === 'skipped') wSkipped = width;
      else if (seg.variant === 'invalid') wInvalid = width;
    });
    var rm = reducedMotion();
    var parts = [];
    parts.push(
      '<div class="csv-import-viz" style="--w-valid:' + wValid + '%;--w-skipped:' + wSkipped + '%;--w-invalid:' + wInvalid + '%;" role="status">'
    );
    if (segments.length) {
      parts.push(
        '<div class="csv-import-viz__bar" aria-hidden="true"' +
        (opts.barTitle ? ' title="' + escapeHtml(opts.barTitle) + '"' : '') +
        '>'
      );
      segments.forEach(function (seg) {
        parts.push('<span class="csv-import-viz__seg csv-import-viz__seg--' + seg.variant + '"></span>');
      });
      parts.push('</div>');
    }
    if (statItems.length) {
      parts.push('<div class="csv-import-viz__stats">');
      statItems.forEach(function (item) {
        var cls = 'csv-import-stat';
        if (item.variant === 'valid') cls += ' csv-import-stat--valid';
        if (item.variant === 'invalid') cls += ' csv-import-stat--invalid';
        var c = item.count || 0;
        parts.push(
          '<div class="' + cls + '"><span class="csv-import-stat__num" data-count="' + c + '">' +
          (rm ? c : '0') +
          '</span><span class="csv-import-stat__label">' + escapeHtml(item.label) + '</span></div>'
        );
      });
      parts.push('</div>');
    }
    if (opts.successHtml) {
      parts.push('<p class="csv-import-viz__success">' + opts.successHtml + '</p>');
    }
    (opts.notesHtml || []).forEach(function (html) {
      parts.push('<p class="csv-import-viz__note">' + html + '</p>');
    });
    if (opts.detailsHtml) parts.push(opts.detailsHtml);
    if (opts.errors && opts.errors.length) {
      parts.push('<ul class="csv-import-viz__errors" aria-label="Errors">');
      opts.errors.slice(0, 8).forEach(function (text) {
        parts.push('<li>' + escapeHtml(text) + '</li>');
      });
      if (opts.errors.length > 8) {
        parts.push('<li>… and ' + (opts.errors.length - 8) + ' more</li>');
      }
      parts.push('</ul>');
    }
    parts.push('</div>');
    el.innerHTML = parts.join('');
    scrollToFeedback(el);
    activateViz(el);
  }

  function groupCsvSkipped(skipped) {
    var groups = {};
    (skipped || []).forEach(function (row) {
      var msg = row.message || 'Skipped';
      if (!groups[msg]) groups[msg] = { message: msg, rows: [] };
      groups[msg].rows.push(row.row);
    });
    return Object.keys(groups).map(function (k) {
      var g = groups[k];
      g.rows.sort(function (a, b) { return a - b; });
      return g;
    });
  }

  function cohortProvision(el, data, opts) {
    opts = opts || {};
    var results = data.results || [];
    var s = data.summary || {};
    var total = results.length;
    var created = Math.max(0, Number(s.created || 0));
    var existing = Math.max(0, Number(s.existing || 0));
    var failed = Math.max(0, Number(s.failed || 0));
    var notes = [];
    if (s.welcome_awaiting_review) {
      notes.push(
        'Review the <strong>welcome message</strong> before it is sent to '
        + '<strong>' + s.welcome_awaiting_review + '</strong> clinician'
        + (s.welcome_awaiting_review === 1 ? '' : 's') + '.'
      );
    }
    if (s.welcome_sent) {
      notes.push(
        'Welcome message sent to <strong>' + s.welcome_sent + '</strong> who already completed their profile.'
      );
    }
    if (s.welcome_queued) {
      notes.push(
        'Welcome queued for <strong>' + s.welcome_queued + '</strong> after they finish onboarding.'
      );
    }
    var successHtml = '';
    if (opts.createdCohort) {
      successHtml = 'Cohort <strong>' + escapeHtml(opts.createdCohort) + '</strong> created.';
    } else if (created || existing) {
      successHtml = 'Clinicians added to this cohort.';
    }
    var errors = results
      .filter(function (r) { return r.status === 'failed'; })
      .map(function (r) { return (r.email || '') + (r.error ? ': ' + r.error : ''); });
    render(el, {
      total: total,
      barTitle: 'Breakdown of addresses',
      segments: [
        { count: created, variant: 'valid' },
        { count: existing, variant: 'skipped' },
        { count: failed, variant: 'invalid' },
      ],
      statItems: [
        { count: created, label: 'New accounts', variant: 'valid' },
        { count: total, label: 'Addresses' },
        { count: existing, label: 'Already in DocPass' },
        { count: failed, label: 'Could not add', variant: 'invalid' },
      ].filter(function (item) { return item.count > 0 || item.label === 'Addresses'; }),
      successHtml: successHtml,
      notesHtml: notes,
      errors: errors,
    });
  }

  function cohortMessage(el, data) {
    var sent = Math.max(0, Number(data.sent || 0));
    var failedList = data.failed || [];
    var failed = failedList.length;
    var total = sent + failed;
    var errors = failedList.map(function (f) {
      var id = f.doctor_user_id != null ? 'Clinician #' + f.doctor_user_id : 'Clinician';
      return id + (f.error ? ': ' + f.error : '');
    });
    render(el, {
      total: total,
      barTitle: 'Message delivery',
      segments: [
        { count: sent, variant: 'valid' },
        { count: failed, variant: 'invalid' },
      ],
      statItems: [
        { count: sent, label: 'Sent', variant: 'valid' },
        { count: total, label: 'Recipients' },
        { count: failed, label: 'Could not reach', variant: 'invalid' },
      ].filter(function (item) {
        return item.count > 0 || item.label === 'Recipients';
      }),
      successHtml: sent ? 'Message delivered to everyone who could be reached.' : '',
      errors: errors,
    });
  }

  function bulkTraining(el, data) {
    if (data.aborted) {
      var issued = Number(data.issued || 0);
      var skipped = Number(data.skipped_duplicate || 0);
      var errCount = Number(data.errors || 0);
      render(el, {
        fatalError:
          'Nothing was saved. Fix the roster errors (or wallet size errors) and submit again. Issued: ' +
          issued +
          ' · Skipped (duplicate): ' +
          skipped +
          ' · Errors: ' +
          errCount,
      });
      return;
    }
    var attempted = Number(data.attempted || 0);
    var issuedN = Math.max(0, Number(data.issued || 0));
    var skippedN = Math.max(0, Number(data.skipped_duplicate || 0));
    var errorsN = Math.max(0, Number(data.errors || 0));
    var rowErrors = (data.rows || [])
      .filter(function (r) {
        return r.status === 'error';
      })
      .map(function (r) {
        return (r.roster_line || '') + (r.message ? ': ' + r.message : '');
      });
    render(el, {
      total: attempted,
      denom: attempted || issuedN + skippedN + errorsN || 1,
      barTitle: 'Breakdown of roster',
      segments: [
        { count: issuedN, variant: 'valid' },
        { count: skippedN, variant: 'skipped' },
        { count: errorsN, variant: 'invalid' },
      ],
      statItems: [
        { count: issuedN, label: 'Issued', variant: 'valid' },
        { count: attempted, label: 'In roster' },
        { count: skippedN, label: 'Skipped (duplicate)' },
        { count: errorsN, label: 'Errors', variant: 'invalid' },
      ].filter(function (item) {
        return item.count > 0 || item.label === 'In roster';
      }),
      successHtml: issuedN ? 'Training records issued to clinicians who allowed your trust.' : '',
      errors: rowErrors,
    });
  }

  function singleTraining(el, data, opts) {
    opts = opts || {};
    var issued = Math.max(0, Number(data.issued || 0));
    var errorsN = Math.max(0, Number(data.errors || 0));
    var row0 = (data.rows && data.rows[0]) || {};
    var notes = [];
    if (opts.followUpNote) notes.push(opts.followUpNote);
    if (issued) {
      render(el, {
        segments: [{ count: 1, variant: 'valid' }],
        statItems: [{ count: 1, label: 'Issued', variant: 'valid' }],
        successHtml: escapeHtml(row0.message || 'Training record issued.'),
        notesHtml: notes,
      });
      return;
    }
    render(el, {
      segments: errorsN ? [{ count: 1, variant: 'invalid' }] : [],
      statItems: errorsN ? [{ count: 1, label: 'Not issued', variant: 'invalid' }] : [],
      errors: row0.message ? [row0.message] : ['Could not issue training.'],
    });
  }

  function fileMerge(el, added, total) {
    added = Math.max(0, Number(added || 0));
    total = Math.max(0, Number(total || 0));
    if (!added) {
      clear(el);
      return;
    }
    render(el, {
      total: total,
      segments: [{ count: added, variant: 'valid' }],
      statItems: [
        { count: added, label: 'Added from file', variant: 'valid' },
        { count: total, label: 'Total addresses' },
      ],
      successHtml: 'Addresses added to the list.',
    });
  }

  function trustPackSeed(el, data) {
    var n = (data.topics && data.topics.length) || 0;
    render(el, {
      segments: n ? [{ count: n, variant: 'valid' }] : [],
      statItems: [
        { count: n, label: 'Topics loaded', variant: 'valid' },
      ],
      successHtml: escapeHtml(data.message || 'Trust pack loaded.'),
    });
  }

  function esrImport(el, data, opts) {
    opts = opts || {};
    if (!el) return;
    if (data.fatal_error) {
      render(el, { fatalError: data.fatal_error });
      return;
    }
    var total = Math.max(0, Number(data.total_data_rows || 0));
    var valid = Math.max(0, Number(data.valid_row_count || 0));
    var skippedN = (data.skipped && data.skipped.length) || 0;
    var invalidN = (data.invalid && data.invalid.length) || 0;
    var skippedDup = Number(data.skipped_duplicate_count || 0);
    var notes = [];
    var detailsHtml = '';
    if (data.multi_person_export) {
      notes.push(
        'Team or trust-wide export — only <strong>your</strong> training is imported. Other people’s rows are skipped automatically.'
      );
    } else if (skippedN && !invalidN) {
      notes.push('Some rows were skipped because they don’t apply to your profile.');
    }
    if (skippedN) {
      var groups = groupCsvSkipped(data.skipped);
      var detailParts = [
        '<details><summary>Why were ' +
          skippedN +
          ' row' +
          (skippedN === 1 ? '' : 's') +
          ' skipped?</summary><ul class="csv-import-skip-groups">',
      ];
      groups.forEach(function (g) {
        var rowLabel = g.rows.length > 8 ? g.rows.slice(0, 8).join(', ') + '…' : g.rows.join(', ');
        detailParts.push(
          '<li><strong>' +
            g.rows.length +
            '</strong> — ' +
            escapeHtml(g.message) +
            (g.rows.length
              ? ' <span style="opacity:0.85;">(rows ' + escapeHtml(rowLabel) + ')</span>'
              : '') +
            '</li>'
        );
      });
      detailParts.push('</ul></details>');
      detailsHtml = detailParts.join('');
    }
    var errors = (data.invalid || []).slice(0, 8).map(function (row) {
      return 'Row ' + row.row + ': ' + (row.message || '');
    });
    if (data.invalid && data.invalid.length > 8) {
      errors.push('… and ' + (data.invalid.length - 8) + ' more');
    }
    var successHtml = '';
    if (opts.imported) {
      successHtml = 'Issued ' + opts.imported + ' training record(s). They appear in My training.';
    } else if (opts.allDuplicates) {
      successHtml = 'No new records were added; everything matched training you already have.';
    }
    if (skippedDup > 0) {
      notes.push('Skipped <strong>' + skippedDup + '</strong> duplicate row(s) already in your list.');
    }
    render(el, {
      total: total,
      barTitle: 'Breakdown of rows in your file',
      segments: [
        { count: valid, variant: 'valid' },
        { count: skippedN, variant: 'skipped' },
        { count: invalidN, variant: 'invalid' },
      ],
      statItems: [
        { count: valid, label: 'Ready to import', variant: 'valid' },
        { count: total, label: 'Rows in file' },
        { count: skippedN, label: 'Skipped' },
        { count: invalidN, label: 'Need fixing', variant: 'invalid' },
      ].filter(function (item) {
        return item.count > 0 || item.label === 'Rows in file';
      }),
      successHtml: successHtml,
      notesHtml: notes,
      errors: errors,
      detailsHtml: detailsHtml,
    });
  }

  w.NHSBatchResultViz = {
    escapeHtml: escapeHtml,
    reducedMotion: reducedMotion,
    clear: clear,
    showLoading: showLoading,
    updateLoadingProgress: updateLoadingProgress,
    progressShowsBar: progressShowsBar,
    readNdjsonStream: readNdjsonStream,
    postNdjsonStream: postNdjsonStream,
    postBulkTrainingStream: postBulkTrainingStream,
    scrollToFeedback: scrollToFeedback,
    render: render,
    animateStatNumbers: animateStatNumbers,
    cohortProvision: cohortProvision,
    cohortMessage: cohortMessage,
    bulkTraining: bulkTraining,
    singleTraining: singleTraining,
    fileMerge: fileMerge,
    trustPackSeed: trustPackSeed,
    esrImport: esrImport,
  };
})(window);
