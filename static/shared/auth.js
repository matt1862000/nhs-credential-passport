/**
 * Shared client-side auth + wallet sync used by all authenticated pages.
 * All pages should call NHSAuth.refresh() once on load.
 */
(function () {
  function getLocalWallet() {
    return window.NHSWallet
      ? NHSWallet.getWallet()
      : JSON.parse(localStorage.getItem('nhs_credentials') || '[]');
  }

  function setLocalWallet(arr) {
    if (window.NHSWallet) NHSWallet.saveWallet(arr);
    else localStorage.setItem('nhs_credentials', JSON.stringify(arr));
  }

  function setLocalWalletFromServer(arr) {
    try {
      localStorage.setItem('nhs_credentials', JSON.stringify(arr || []));
    } catch (e) {}
    if (window.NHSWallet && NHSWallet.clearDirty) {
      try {
        NHSWallet.clearDirty();
      } catch (e2) {}
    }
  }

  function mergeByCredentialId(a, b) {
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

  async function readJsonOrText(res) {
    var text = await res.text();
    var data = null;
    try {
      data = text ? JSON.parse(text) : null;
    } catch (e) {
      data = null;
    }
    return { data: data, text: text };
  }

  var NHSAuth = {
    user: null,

    async refresh() {
      try {
        var r = await fetch('/api/auth/me', { credentials: 'include' });
        this.user = r.ok ? await r.json() : null;
      } catch (e) {
        this.user = null;
      }
      /* Backwards compatible mirror used by older scripts (trust-mover etc.). */
      window.__nhsAuthUser = this.user;
      window.dispatchEvent(
        new CustomEvent('nhs-auth-changed', { detail: { user: this.user } })
      );
      return this.user;
    },

    async signIn(email, password) {
      var r = await fetch('/api/auth/login', {
        method: 'POST',
        credentials: 'include',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email: email, password: password }),
      });
      var parsed = await readJsonOrText(r);
      if (!r.ok) {
        var d = parsed.data && parsed.data.detail;
        throw new Error(typeof d === 'string' ? d : 'Could not sign in');
      }
      await this.refresh();
      return this.user;
    },

    async register(email, password) {
      var r = await fetch('/api/auth/register', {
        method: 'POST',
        credentials: 'include',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email: email, password: password }),
      });
      var parsed = await readJsonOrText(r);
      if (!r.ok) {
        var d = parsed.data && parsed.data.detail;
        throw new Error(typeof d === 'string' ? d : 'Could not create account');
      }
      await this.refresh();
      /* New accounts must start with an empty server wallet, regardless of prior device state. */
      await this.pushWallet([]);
      setLocalWalletFromServer([]);
      window.dispatchEvent(new CustomEvent('nhs-wallet-updated'));
      return this.user;
    },

    async signOut() {
      try {
        await fetch('/api/auth/logout', {
          method: 'POST',
          credentials: 'include',
        });
      } catch (e) {}
      this.user = null;
      window.__nhsAuthUser = null;
      try {
        if (window.NHSWallet && typeof NHSWallet.resetDeviceWalletCache === 'function') {
          await NHSWallet.resetDeviceWalletCache();
        } else {
          try {
            localStorage.removeItem('nhs_credentials');
          } catch (e2) {}
        }
      } catch (e) {}
      window.dispatchEvent(
        new CustomEvent('nhs-auth-changed', { detail: { user: null } })
      );
    },

    async pullWalletMerge() {
      if (!this.user) return;
      try {
        var r = await fetch('/api/me/wallet', { credentials: 'include' });
        if (!r.ok) return;
        var server = await r.json();
        if (!Array.isArray(server)) server = [];
        var local = getLocalWallet();
        var merged;
        /* Empty server wallet = account never used; do not merge stale localStorage from this browser
           (another user / old anonymous data). Once server has rows, merge: server wins on same credential_id. */
        if (server.length === 0) {
          merged = [];
        } else {
          merged = mergeByCredentialId(local, server);
        }
        setLocalWalletFromServer(merged);
        window.dispatchEvent(new CustomEvent('nhs-wallet-updated'));
      } catch (e) {
        console.warn('Wallet pull failed', e);
      }
    },

    async pushWallet(arr) {
      if (!this.user) return;
      try {
        await fetch('/api/me/wallet', {
          method: 'PUT',
          credentials: 'include',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(arr),
        });
      } catch (e) {
        console.warn('Wallet push failed', e);
      }
    },

    async updateProfile(payload) {
      if (!this.user) return;
      var r = await fetch('/api/me/profile', {
        method: 'PUT',
        credentials: 'include',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload || {}),
      });
      var parsed = await readJsonOrText(r);
      if (!r.ok) {
        var d = parsed.data && parsed.data.detail;
        throw new Error(typeof d === 'string' ? d : 'Could not save profile');
      }
      await this.refresh();
    },

    /**
     * Force redirect to /static/auth/ if not authenticated. Returns true if
     * authenticated, false otherwise.
     */
    requireAuth(loginUrl) {
      if (this.user) return true;
      var path = window.location.pathname + window.location.search + window.location.hash;
      var next = encodeURIComponent(path);
      window.location.replace((loginUrl || '/static/auth/') + '?next=' + next);
      return false;
    },

    redirectAfterAuth(fallback) {
      var p = new URLSearchParams(window.location.search);
      var next = p.get('next');
      if (next && /^\/(static\/)?[a-zA-Z0-9_\-/?=&%.#]*$/.test(next)) {
        window.location.replace(next);
        return;
      }
      window.location.replace(fallback || '/static/dashboard/');
    },
  };

  window.NHSAuth = NHSAuth;
})();
