/**
 * Match wallet credentials to trust mandatory topics (same rules as plan-move trust-mover).
 */
(function (global) {
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

  function credPayload(c) {
    if (!c || c.revoked) return null;
    var code = (c.module_code || '').toLowerCase();
    var name = (c.module_name || '').toLowerCase();
    if (!code && c.jwt) {
      var pl = parseJwtPayload(c.jwt);
      if (pl) {
        code = (pl.module_code || '').toLowerCase();
        if (!name) name = (pl.module_name || '').toLowerCase();
      }
    }
    return { module_code: code, module_name: name };
  }

  function hintsFromTopic(topic) {
    var h = topic.match_hints;
    if (h && typeof h === 'object') return h;
    return {
      match_module_codes: [],
      match_name_substrings: [topic.topic_name || ''],
    };
  }

  function credMatchesRequirement(req, pl) {
    if (!pl) return false;
    var code = pl.module_code || '';
    var name = pl.module_name || '';
    var codes = req.match_module_codes || [];
    var i;
    for (i = 0; i < codes.length; i++) {
      if (code === String(codes[i]).toLowerCase()) return true;
    }
    var subs = req.match_name_substrings || [];
    for (i = 0; i < subs.length; i++) {
      if (name.indexOf(String(subs[i]).toLowerCase()) !== -1) return true;
    }
    return false;
  }

  function findBestMatch(topic, wallet) {
    var req = hintsFromTopic(topic);
    var label = (topic.topic_name || '').toLowerCase().trim();
    var matches = [];
    wallet.forEach(function (c) {
      var pl = credPayload(c);
      if (!pl) return;
      if (credMatchesRequirement(req, pl)) {
        matches.push(c);
        return;
      }
      if (label && (pl.module_name.indexOf(label) !== -1 || label.indexOf(pl.module_name) !== -1)) {
        matches.push(c);
      }
    });
    if (!matches.length) return null;
    matches.sort(function (a, b) {
      var ae = a.expiry_date || '9999-99-99';
      var be = b.expiry_date || '9999-99-99';
      return be > ae ? 1 : be < ae ? -1 : 0;
    });
    return matches[0];
  }

  global.NHSMandatoryMatch = {
    credPayload: credPayload,
    credMatchesRequirement: credMatchesRequirement,
    findBestMatch: findBestMatch,
    hintsFromTopic: hintsFromTopic,
  };
})(typeof window !== 'undefined' ? window : globalThis);
