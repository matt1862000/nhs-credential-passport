/**
 * Home page: same optional account + server wallet sync as /static/staff/,
 * so clinicians can register without opening My e-learning first.
 */
(function () {
  function getStored() {
    return window.NHSWallet ? NHSWallet.getWallet() : JSON.parse(localStorage.getItem('nhs_credentials') || '[]');
  }

  window.__nhsAuthUser = null;

  async function syncWalletToServer(arr) {
    if (!window.__nhsAuthUser) return;
    try {
      await fetch('/api/me/wallet', {
        method: 'PUT',
        credentials: 'include',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(arr),
      });
    } catch (e) {
      console.warn('Wallet server sync failed', e);
    }
  }

  function setStored(arr) {
    if (window.NHSWallet) NHSWallet.saveWallet(arr);
    else {
      localStorage.setItem('nhs_credentials', JSON.stringify(arr));
      void syncWalletToServer(arr);
    }
    window.dispatchEvent(new CustomEvent('nhs-wallet-updated'));
  }

  function showHomeAuthFeedback(msg) {
    var el = document.getElementById('homeAuthFeedback');
    if (!el) return;
    if (msg) {
      el.textContent = msg;
      el.hidden = false;
    } else {
      el.textContent = '';
      el.hidden = true;
    }
  }

  function updateHomeStepGating() {
    var isAuthed = !!window.__nhsAuthUser;
    var step2 = document.getElementById('homeStep2');
    var step3 = document.getElementById('homeStep3');
    var step4 = document.getElementById('homeStep4');
    var step2Lock = document.getElementById('homeStep2LockedMsg');
    var step3Lock = document.getElementById('homeStep3LockedMsg');
    var step4Lock = document.getElementById('homeStep4LockedMsg');
    var step2Import = document.getElementById('homeStep2ImportLink');
    var step2WalletLabel = document.getElementById('homeStep2WalletLabel');
    var step2WalletInput = document.getElementById('movingWalletFileInput');
    var join = document.getElementById('joinTrust');
    var leave = document.getElementById('leaveTrust');
    var refresh = document.getElementById('btnRefreshChecklist');
    var movingResults = document.getElementById('movingResults');
    var movingError = document.getElementById('movingError');

    [step2, step3, step4].forEach(function (el) {
      if (!el) return;
      if (isAuthed) el.classList.remove('is-locked');
      else el.classList.add('is-locked');
    });
    if (step2Lock) step2Lock.hidden = isAuthed;
    if (step3Lock) step3Lock.hidden = isAuthed;
    if (step4Lock) step4Lock.hidden = isAuthed;

    if (step2Import) {
      if (isAuthed) step2Import.removeAttribute('aria-disabled');
      else step2Import.setAttribute('aria-disabled', 'true');
      step2Import.style.pointerEvents = isAuthed ? '' : 'none';
      step2Import.style.opacity = isAuthed ? '' : '0.65';
    }
    if (step2WalletLabel) {
      step2WalletLabel.style.pointerEvents = isAuthed ? '' : 'none';
      step2WalletLabel.style.opacity = isAuthed ? '' : '0.65';
    }
    if (step2WalletInput) step2WalletInput.disabled = !isAuthed;
    if (join) join.disabled = !isAuthed;
    if (leave) leave.disabled = !isAuthed;
    if (refresh) refresh.disabled = !isAuthed;

    if (!isAuthed) {
      if (movingResults) {
        movingResults.hidden = true;
        movingResults.setAttribute('aria-hidden', 'true');
      }
      if (movingError) movingError.textContent = '';
    }

    window.dispatchEvent(new CustomEvent('nhs-auth-changed', { detail: { authed: isAuthed } }));
  }

  async function refreshAuthState() {
    window.__nhsAuthUser = null;
    try {
      var r = await fetch('/api/auth/me', { credentials: 'include' });
      if (r.ok) window.__nhsAuthUser = await r.json();
    } catch (e) {}
    updateHomeAuthUi();
    updateHomeStepGating();
  }

  function updateHomeAuthUi() {
    var g = document.getElementById('homeAuthGuest');
    var u = document.getElementById('homeAuthUser');
    if (!g || !u) return;
    if (window.__nhsAuthUser) {
      showHomeAuthFeedback('');
      g.hidden = true;
      u.hidden = false;
      var em = document.getElementById('homeAuthUserEmail');
      if (em) em.textContent = __nhsAuthUser.email || '';
    } else {
      g.hidden = false;
      u.hidden = true;
    }
  }

  /** First array fills the map; second wins on duplicate credential_id (caller passes local, then server). */
  function mergeServerAndLocal(a, b) {
    if (window.NHSWallet && NHSWallet.mergeByCredentialId) {
      return NHSWallet.mergeByCredentialId(a || [], b || []);
    }
    var map = {};
    (a || []).forEach(function (c) {
      if (c && c.credential_id) map[c.credential_id] = c;
    });
    (b || []).forEach(function (c) {
      if (c && c.credential_id) map[c.credential_id] = c;
    });
    return Object.keys(map).map(function (k) {
      return map[k];
    });
  }

  async function pullMergeFromServer() {
    if (!window.__nhsAuthUser) return;
    try {
      var r = await fetch('/api/me/wallet', { credentials: 'include' });
      if (!r.ok) return;
      var server = await r.json();
      if (!Array.isArray(server)) server = [];
      var local = getStored();
      var merged;
      if (!server.length) {
        merged = [];
      } else {
        merged =
          window.NHSWallet && NHSWallet.mergeByCredentialId
            ? NHSWallet.mergeByCredentialId(local, server)
            : mergeServerAndLocal(local, server);
      }
      setStored(merged);
    } catch (e) {
      console.warn('Wallet merge from server', e);
    }
  }

  async function authJson(path, body) {
    var res = await fetch(path, {
      method: 'POST',
      credentials: 'include',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    var text = await res.text();
    var data = null;
    try {
      data = text ? JSON.parse(text) : null;
    } catch (e) {
      data = null;
    }
    return { ok: res.ok, status: res.status, data: data, text: text };
  }

  function wireForms() {
    var fr = document.getElementById('homeFormRegister');
    var fl = document.getElementById('homeFormLogin');
    var lo = document.getElementById('homeBtnLogout');
    if (fr) {
      fr.addEventListener('submit', async function (e) {
        e.preventDefault();
        showHomeAuthFeedback('');
        var fd = new FormData(fr);
        var email = (fd.get('email') || '').trim();
        var password = fd.get('password') || '';
        var out = await authJson('/api/auth/register', { email: email, password: password });
        if (!out.ok) {
          var det = out.data && out.data.detail;
          showHomeAuthFeedback(typeof det === 'string' ? det : (out.text || 'Could not create account'));
          return;
        }
        await refreshAuthState();
        await syncWalletToServer([]);
        if (window.NHSWallet && typeof NHSWallet.resetDeviceWalletCache === 'function') {
          await NHSWallet.resetDeviceWalletCache();
        }
        await pullMergeFromServer();
        fr.reset();
        var esr = document.getElementById('home-step-esr');
        if (esr) {
          esr.scrollIntoView({ behavior: 'smooth', block: 'start' });
          esr.setAttribute('tabindex', '-1');
          esr.focus();
        }
      });
    }
    if (fl) {
      fl.addEventListener('submit', async function (e) {
        e.preventDefault();
        showHomeAuthFeedback('');
        var fd = new FormData(fl);
        var email = (fd.get('email') || '').trim();
        var password = fd.get('password') || '';
        var out = await authJson('/api/auth/login', { email: email, password: password });
        if (!out.ok) {
          var det = out.data && out.data.detail;
          showHomeAuthFeedback(typeof det === 'string' ? det : (out.text || 'Could not sign in'));
          return;
        }
        await refreshAuthState();
        if (window.NHSWallet && typeof NHSWallet.resetDeviceWalletCache === 'function') {
          await NHSWallet.resetDeviceWalletCache();
        }
        await pullMergeFromServer();
        fl.reset();
        var esr2 = document.getElementById('home-step-esr');
        if (esr2) {
          esr2.scrollIntoView({ behavior: 'smooth', block: 'start' });
          esr2.setAttribute('tabindex', '-1');
          esr2.focus();
        }
      });
    }
    if (lo) {
      lo.addEventListener('click', async function () {
        try {
          await fetch('/api/auth/logout', { method: 'POST', credentials: 'include' });
        } catch (err) {}
        showHomeAuthFeedback('');
        await refreshAuthState();
        window.dispatchEvent(new CustomEvent('nhs-wallet-updated'));
      });
    }
  }

  async function boot() {
    if (!window.NHSWallet) return;
    await refreshAuthState();
    if (window.__nhsAuthUser) await pullMergeFromServer();
    window.dispatchEvent(new CustomEvent('nhs-wallet-updated'));
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () {
      wireForms();
      void boot();
    });
  } else {
    wireForms();
    void boot();
  }
})();
