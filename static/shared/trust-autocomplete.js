/**
 * Wire NHS ORD trust name autocomplete on an input (requires NHSOdsTrustSuggest).
 * opts: { inputId, listId, wrapId, metaClass }
 */
(function (w) {
  function wire(opts) {
    opts = opts || {};
    var inputId = opts.inputId || 'currentTrust';
    var listId = opts.listId || 'trustSuggestList';
    var wrapId = opts.wrapId || 'trustAcWrap';
    var metaClass = opts.metaClass || 'trust-suggest-meta';

    var inp = document.getElementById(inputId);
    var wrap = document.getElementById(wrapId);
    var list = document.getElementById(listId);
    if (!inp || !list) return;

    var debounce = null;
    var items = [];
    var active = -1;

    function hide() {
      list.hidden = true;
      list.innerHTML = '';
      items = [];
      active = -1;
      inp.setAttribute('aria-expanded', 'false');
      inp.removeAttribute('aria-activedescendant');
    }

    function applyIndex(idx) {
      if (idx < 0 || idx >= items.length) return;
      inp.value = items[idx].name;
      hide();
    }

    function updateHighlight() {
      var lis = list.querySelectorAll('li[role="option"]');
      for (var j = 0; j < lis.length; j++) {
        lis[j].setAttribute('aria-selected', j === active ? 'true' : 'false');
      }
      if (active >= 0 && lis[active]) {
        inp.setAttribute('aria-activedescendant', lis[active].id);
        try {
          lis[active].scrollIntoView({ block: 'nearest' });
        } catch (e2) {}
      } else {
        inp.removeAttribute('aria-activedescendant');
      }
    }

    function render(suggestions) {
      items = suggestions || [];
      list.innerHTML = '';
      active = -1;
      if (!items.length) {
        hide();
        return;
      }
      for (var i = 0; i < items.length; i++) {
        var it = items[i];
        var li = document.createElement('li');
        li.setAttribute('role', 'option');
        li.id = inputId + '-trust-opt-' + i;
        li.dataset.index = String(i);
        var nameSpan = document.createElement('span');
        nameSpan.textContent = it.name;
        li.appendChild(nameSpan);
        if (it.ods) {
          var meta = document.createElement('span');
          meta.className = metaClass;
          meta.textContent = 'ODS ' + it.ods;
          li.appendChild(meta);
        }
        list.appendChild(li);
      }
      list.hidden = false;
      inp.setAttribute('aria-expanded', 'true');
    }

    async function run() {
      if (!w.NHSOdsTrustSuggest) return;
      var q = String(inp.value || '').trim();
      if (q.length < 2) {
        hide();
        return;
      }
      try {
        var found = await NHSOdsTrustSuggest.search(q, { minLength: 2, limit: 8 });
        render(found);
      } catch (e) {
        hide();
      }
    }

    function schedule() {
      if (debounce) clearTimeout(debounce);
      debounce = setTimeout(function () {
        debounce = null;
        void run();
      }, 320);
    }

    list.addEventListener('mousedown', function (ev) {
      if (ev.target.closest('li[role="option"]')) ev.preventDefault();
    });
    list.addEventListener('click', function (ev) {
      var li = ev.target.closest('li[role="option"]');
      if (!li) return;
      applyIndex(parseInt(li.dataset.index, 10));
    });
    inp.addEventListener('input', schedule);
    inp.addEventListener('keydown', function (e) {
      if (list.hidden || !items.length) return;
      if (e.key === 'Escape') {
        e.preventDefault();
        hide();
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
    inp.addEventListener('blur', function () {
      setTimeout(hide, 200);
    });
    document.addEventListener('click', function (e) {
      if (wrap && !wrap.contains(e.target)) hide();
    });

    return { hide: hide };
  }

  w.NHSTrustAutocomplete = { wire: wire };
})(typeof window !== 'undefined' ? window : this);
