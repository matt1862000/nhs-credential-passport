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
    else localStorage.setItem('nhs_credentials', JSON.stringify(arr));
    void syncWalletToServer(arr);
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

  async function refreshAuthState() {
    window.__nhsAuthUser = null;
    try {
      var r = await fetch('/api/auth/me', { credentials: 'include' });
      if (r.ok) window.__nhsAuthUser = await r.json();
    } catch (e) {}
    updateHomeAuthUi();
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

  function mergeServerAndLocal(serverArr, localArr) {
    if (window.NHSWallet && NHSWallet.mergeByCredentialId) {
      return NHSWallet.mergeByCredentialId(serverArr || [], localArr || []);
    }
    var map = {};
    (serverArr || []).forEach(function (c) {
      if (c && c.credential_id) map[c.credential_id] = c;
    });
    (localArr || []).forEach(function (c) {
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
      var merged = mergeServerAndLocal(server, getStored());
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

  /** Called from moving-home-wallet.js after file merge/replace. */
  window.__nhsAfterWalletLocalChange = function () {
    if (!window.__nhsAuthUser || !window.NHSWallet) return;
    void syncWalletToServer(NHSWallet.getWallet());
  };

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
        await pullMergeFromServer();
        fr.reset();
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
        await pullMergeFromServer();
        fl.reset();
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
    if (NHSWallet.restoreLinkedHandle) await NHSWallet.restoreLinkedHandle();
    await refreshAuthState();
    if (window.__nhsAuthUser) await pullMergeFromServer();
    /* Re-run move planner after linked-file restore or server merge (trust-mover may have run earlier). */
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
