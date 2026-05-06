/**
 * Wallet: localStorage cache (same key as before) + optional JSON file for portability.
 * When signed in, saveWallet (and linking a sync file) also PUTs to /api/me/wallet.
 * File format: { "version": 1, "credentials": [...] } or a raw JSON array.
 */
(function () {
  var STORAGE_KEY = 'nhs_credentials';
  var DB_NAME = 'nhs_credential_wallet_v1';
  var STORE_NAME = 'handles';
  var LINK_ID = 'wallet_json';
  var DIRTY_KEY = 'nhs_wallet_dirty';
  var BANNER_DISMISS_KEY = 'nhs_wallet_save_banner_dismissed';
  var linkedHandle = null;

  function markDirty() {
    try {
      sessionStorage.setItem(DIRTY_KEY, '1');
      sessionStorage.removeItem(BANNER_DISMISS_KEY);
    } catch (e) {}
  }

  function clearDirty() {
    try {
      sessionStorage.removeItem(DIRTY_KEY);
    } catch (e) {}
  }

  function isDirty() {
    try {
      return sessionStorage.getItem(DIRTY_KEY) === '1';
    } catch (e) {
      return false;
    }
  }

  function getWallet() {
    try {
      var raw = localStorage.getItem(STORAGE_KEY) || '[]';
      var arr = JSON.parse(raw);
      return Array.isArray(arr) ? arr : [];
    } catch (e) {
      return [];
    }
  }

  function setWalletLocal(arr) {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(arr));
  }

  function parseWalletJson(text) {
    var o = JSON.parse(text);
    if (Array.isArray(o)) return o;
    if (o && Array.isArray(o.credentials)) return o.credentials;
    throw new Error('This file should be a list of training records: either a JSON array or an object with a "credentials" section.');
  }

  function serializeWallet(arr) {
    return JSON.stringify(
      { version: 1, exported_at: new Date().toISOString(), credentials: arr },
      null,
      2
    );
  }

  /** Push current wallet to server when a session exists (shared auth or legacy home flag). */
  function pushWalletIfAuthed(arr) {
    try {
      if (window.NHSAuth && NHSAuth.user && typeof NHSAuth.pushWallet === 'function') {
        void NHSAuth.pushWallet(arr);
        return;
      }
    } catch (e) {}
    try {
      if (window.__nhsAuthUser) {
        void fetch('/api/me/wallet', {
          method: 'PUT',
          credentials: 'include',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(arr),
        }).catch(function () {});
      }
    } catch (e2) {}
  }

  function mergeByCredentialId(existing, incoming) {
    var map = {};
    (existing || []).forEach(function (c) {
      if (c && c.credential_id) map[c.credential_id] = c;
    });
    (incoming || []).forEach(function (c) {
      if (c && c.credential_id) map[c.credential_id] = c;
    });
    return Object.keys(map).map(function (k) {
      return map[k];
    });
  }

  function downloadWalletBackup(arr) {
    var blob = new Blob([serializeWallet(arr)], { type: 'application/json;charset=utf-8' });
    var a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'nhs-elearning-training-list.json';
    a.click();
    URL.revokeObjectURL(a.href);
    clearDirty();
  }

  function openDB() {
    return new Promise(function (resolve, reject) {
      var req = indexedDB.open(DB_NAME, 1);
      req.onupgradeneeded = function () {
        req.result.createObjectStore(STORE_NAME);
      };
      req.onsuccess = function () {
        resolve(req.result);
      };
      req.onerror = function () {
        reject(req.error);
      };
    });
  }

  function idbPutHandle(handle) {
    return openDB().then(function (db) {
      return new Promise(function (resolve, reject) {
        var tx = db.transaction(STORE_NAME, 'readwrite');
        tx.objectStore(STORE_NAME).put(handle, LINK_ID);
        tx.oncomplete = function () {
          db.close();
          resolve();
        };
        tx.onerror = function () {
          reject(tx.error);
        };
      });
    });
  }

  function idbGetHandle() {
    return openDB().then(function (db) {
      return new Promise(function (resolve, reject) {
        var tx = db.transaction(STORE_NAME, 'readonly');
        var req = tx.objectStore(STORE_NAME).get(LINK_ID);
        req.onsuccess = function () {
          db.close();
          resolve(req.result || null);
        };
        req.onerror = function () {
          reject(req.error);
        };
      });
    });
  }

  function idbDeleteHandle() {
    return openDB().then(function (db) {
      return new Promise(function (resolve, reject) {
        var tx = db.transaction(STORE_NAME, 'readwrite');
        tx.objectStore(STORE_NAME).delete(LINK_ID);
        tx.oncomplete = function () {
          db.close();
          resolve();
        };
        tx.onerror = function () {
          reject(tx.error);
        };
      });
    });
  }

  async function writeToLinked(arr) {
    if (!linkedHandle) return false;
    try {
      var perm = await linkedHandle.queryPermission({ mode: 'readwrite' });
      if (perm !== 'granted') perm = await linkedHandle.requestPermission({ mode: 'readwrite' });
      if (perm !== 'granted') return false;
      var w = await linkedHandle.createWritable();
      await w.write(serializeWallet(arr));
      await w.close();
      return true;
    } catch (e) {
      console.warn('NHSWallet: could not write linked file', e);
      return false;
    }
  }

  function saveWallet(arr, skipDirty) {
    setWalletLocal(arr);
    if (!skipDirty) markDirty();
    pushWalletIfAuthed(arr);
    void (async function () {
      if (await writeToLinked(arr)) clearDirty();
    })();
  }

  async function restoreLinkedHandle() {
    if (typeof window.showOpenFilePicker !== 'function') return;
    try {
      var h = await idbGetHandle();
      if (!h) return;
      linkedHandle = h;
      var perm = await linkedHandle.queryPermission({ mode: 'readwrite' });
      if (perm !== 'granted') {
        perm = await linkedHandle.requestPermission({ mode: 'readwrite' });
      }
      if (perm !== 'granted') return;
      var file = await linkedHandle.getFile();
      var text = await file.text();
      var imported = parseWalletJson(text);
      setWalletLocal(imported);
      clearDirty();
    } catch (e) {
      console.warn('NHSWallet: could not restore linked file', e);
    }
  }

  async function linkWalletFile() {
    if (typeof window.showOpenFilePicker !== 'function') {
      throw new Error('To keep one file updated automatically, use Google Chrome or Microsoft Edge on a computer.');
    }
    var handles = await window.showOpenFilePicker({
      types: [{ description: 'Training list backup', accept: { 'application/json': ['.json'] } }],
      excludeAcceptAllOption: false,
      multiple: false,
    });
    var handle = handles[0];
    linkedHandle = handle;
    await idbPutHandle(handle);
    var file = await handle.getFile();
    var arr = parseWalletJson(await file.text());
    setWalletLocal(arr);
    pushWalletIfAuthed(arr);
    await writeToLinked(arr);
    clearDirty();
    return { count: arr.length, name: file.name };
  }

  async function unlinkWalletFile() {
    linkedHandle = null;
    await idbDeleteHandle();
    markDirty();
  }

  async function loadWalletFromFileText(text, mode) {
    var incoming = parseWalletJson(text);
    var existing = getWallet();
    var next = mode === 'replace' ? incoming : mergeByCredentialId(existing, incoming);
    saveWallet(next);
    return { count: next.length, merged: mode !== 'replace' };
  }

  function dismissSaveBanner() {
    try {
      sessionStorage.setItem(BANNER_DISMISS_KEY, '1');
    } catch (e) {}
  }

  function isSaveBannerDismissed() {
    try {
      return sessionStorage.getItem(BANNER_DISMISS_KEY) === '1';
    } catch (e) {
      return false;
    }
  }

  function hasFilePicker() {
    return typeof window.showOpenFilePicker === 'function';
  }

  function isLinked() {
    return !!linkedHandle;
  }

  function getLinkedFileName() {
    return linkedHandle && linkedHandle.name ? linkedHandle.name : '';
  }

  /**
   * Clear this browser's wallet cache and linked JSON file handle (no server PUT).
   * Used after sign-out and before the first merge for a newly registered account so
   * another user's or an old anonymous list in localStorage is not merged into the new account.
   */
  async function resetDeviceWalletCache() {
    clearDirty();
    try {
      sessionStorage.removeItem(BANNER_DISMISS_KEY);
    } catch (e) {}
    linkedHandle = null;
    try {
      await idbDeleteHandle();
    } catch (e) {}
    setWalletLocal([]);
  }

  window.NHSWallet = {
    STORAGE_KEY: STORAGE_KEY,
    getWallet: getWallet,
    saveWallet: saveWallet,
    parseWalletJson: parseWalletJson,
    serializeWallet: serializeWallet,
    mergeByCredentialId: mergeByCredentialId,
    downloadWalletBackup: downloadWalletBackup,
    restoreLinkedHandle: restoreLinkedHandle,
    linkWalletFile: linkWalletFile,
    unlinkWalletFile: unlinkWalletFile,
    loadWalletFromFileText: loadWalletFromFileText,
    hasFilePicker: hasFilePicker,
    isLinked: isLinked,
    getLinkedFileName: getLinkedFileName,
    isDirty: isDirty,
    clearDirty: clearDirty,
    markDirty: markDirty,
    dismissSaveBanner: dismissSaveBanner,
    isSaveBannerDismissed: isSaveBannerDismissed,
    resetDeviceWalletCache: resetDeviceWalletCache,
  };
})();
