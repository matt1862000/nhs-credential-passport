/**
 * Wallet: localStorage cache (same key as before) + optional JSON file for portability.
 * File format: { "version": 1, "credentials": [...] } or a raw JSON array.
 */
(function () {
  var STORAGE_KEY = 'nhs_credentials';
  var DB_NAME = 'nhs_credential_wallet_v1';
  var STORE_NAME = 'handles';
  var LINK_ID = 'wallet_json';
  var linkedHandle = null;

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
    throw new Error('Wallet file must be a JSON array or an object with a "credentials" array.');
  }

  function serializeWallet(arr) {
    return JSON.stringify(
      { version: 1, exported_at: new Date().toISOString(), credentials: arr },
      null,
      2
    );
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
    a.download = 'nhs-elearning-wallet.json';
    a.click();
    URL.revokeObjectURL(a.href);
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
    if (!linkedHandle) return;
    try {
      var perm = await linkedHandle.queryPermission({ mode: 'readwrite' });
      if (perm !== 'granted') perm = await linkedHandle.requestPermission({ mode: 'readwrite' });
      if (perm !== 'granted') return;
      var w = await linkedHandle.createWritable();
      await w.write(serializeWallet(arr));
      await w.close();
    } catch (e) {
      console.warn('NHSWallet: could not write linked file', e);
    }
  }

  function saveWallet(arr) {
    setWalletLocal(arr);
    void writeToLinked(arr);
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
    } catch (e) {
      console.warn('NHSWallet: could not restore linked file', e);
    }
  }

  async function linkWalletFile() {
    if (typeof window.showOpenFilePicker !== 'function') {
      throw new Error('Linking a file for automatic saves needs a Chromium-based browser (Chrome or Edge).');
    }
    var handles = await window.showOpenFilePicker({
      types: [{ description: 'Wallet JSON', accept: { 'application/json': ['.json'] } }],
      excludeAcceptAllOption: false,
      multiple: false,
    });
    var handle = handles[0];
    linkedHandle = handle;
    await idbPutHandle(handle);
    var file = await handle.getFile();
    var arr = parseWalletJson(await file.text());
    setWalletLocal(arr);
    return { count: arr.length, name: file.name };
  }

  async function unlinkWalletFile() {
    linkedHandle = null;
    await idbDeleteHandle();
  }

  async function loadWalletFromFileText(text, mode) {
    var incoming = parseWalletJson(text);
    var existing = getWallet();
    var next = mode === 'replace' ? incoming : mergeByCredentialId(existing, incoming);
    saveWallet(next);
    return { count: next.length, merged: mode !== 'replace' };
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
  };
})();
