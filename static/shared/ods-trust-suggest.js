/**
 * NHS Organisation Directory (ORD) trust name search — shared by staff + profile.
 * https://directory.spineservices.nhs.uk/ORD/2-0-0/organisations
 *
 * Suggestions are restricted to employer-scale NHS trusts / health boards only (not local
 * authorities, GP hubs, legacy PCTs, trust sites, etc.).
 */
(function (w) {
  var ORD_URL = 'https://directory.spineservices.nhs.uk/ORD/2-0-0/organisations';

  /** Primary roles: NHS Trust (England incl. foundation), Care Trust, Welsh LHB, NI trust, Scottish board. */
  var TRUST_PICKLIST_PRIMARY_ROLE_IDS = {
    RO197: true,
    RO107: true,
    RO142: true,
    RO154: true,
    RO190: true,
  };

  /** Roles queried separately so short Name searches still return trusts/boards (plain Name alone is dominated by non-trust orgs). */
  var TRUST_ROLE_IDS_FOR_QUERY = ['RO197', 'RO107', 'RO142', 'RO154', 'RO190'];

  function normQuery(raw) {
    return (raw || '').toLowerCase().replace(/\s+/g, ' ').trim();
  }

  function isTrustPicklistPrimaryRole(org) {
    var rid = org && org.PrimaryRoleId ? String(org.PrimaryRoleId) : '';
    return !!TRUST_PICKLIST_PRIMARY_ROLE_IDS[rid];
  }

  function scoreOrdOrg(org, q) {
    var nm = org.Name || '';
    var name = nm.toLowerCase().replace(/\s+/g, ' ').trim();
    if ((org.Status || '').toUpperCase() !== 'ACTIVE') return -Infinity;
    if (!isTrustPicklistPrimaryRole(org)) return -Infinity;
    var s = 0;
    if (/trial|covid|octave|comcov|research database|nhs app/i.test(nm)) s -= 55;
    var rid = org.PrimaryRoleId || '';
    if (rid === 'RO197') s += 100;
    else if (rid === 'RO154' || rid === 'RO142' || rid === 'RO190') s += 96;
    else if (rid === 'RO107') s += 92;
    var rc = org.OrgRecordClass || '';
    if (rc === 'RC1') s += 48;
    else if (rc === 'RC2') s += 12;
    if (name === q) s += 75;
    else if (name.startsWith(q)) s += 52;
    else if (name.includes(q)) s += 34;
    else {
      var qw = q.split(' ').filter(function (x) {
        return x.length > 2;
      });
      for (var wi = 0; wi < qw.length; wi++) {
        if (name.includes(qw[wi])) s += 8;
      }
    }
    return s;
  }

  function rankOrgs(orgs, rawQuery) {
    var q = normQuery(rawQuery);
    var rows = [];
    if (!orgs || !orgs.length) return rows;
    for (var i = 0; i < orgs.length; i++) {
      var org = orgs[i];
      var sc = scoreOrdOrg(org, q);
      if (sc >= 40 && sc > -Infinity) rows.push({ org: org, score: sc });
    }
    rows.sort(function (a, b) {
      return b.score - a.score;
    });
    return rows;
  }

  async function fetchOrgMatches(nameQuery, minLen) {
    var t = (nameQuery || '').trim();
    var min = typeof minLen === 'number' ? minLen : 2;
    if (t.length < min) return [];
    var perLimit = 40;
    var fetches = TRUST_ROLE_IDS_FOR_QUERY.map(function (roleId) {
      var url =
        ORD_URL +
        '?Name=' +
        encodeURIComponent(t) +
        '&PrimaryRoleId=' +
        encodeURIComponent(roleId) +
        '&Limit=' +
        perLimit;
      return fetch(url, { headers: { Accept: 'application/json' } })
        .then(function (res) {
          if (!res.ok) return [];
          return res.json().then(function (data) {
            return data.Organisations || [];
          });
        })
        .catch(function () {
          return [];
        });
    });
    var batches = await Promise.all(fetches);
    var byId = {};
    for (var bi = 0; bi < batches.length; bi++) {
      var batch = batches[bi];
      for (var i = 0; i < batch.length; i++) {
        var o = batch[i];
        var id = o.OrgId || '';
        if (!id || byId[id]) continue;
        byId[id] = o;
      }
    }
    var merged = [];
    for (var k in byId) {
      if (Object.prototype.hasOwnProperty.call(byId, k)) merged.push(byId[k]);
    }
    return merged;
  }

  w.NHSOdsTrustSuggest = {
    scoreOrdOrg: scoreOrdOrg,

    /**
     * Top trust suggestions for autocomplete (official directory names).
     * @param {string} nameQuery
     * @param {{ minLength?: number, limit?: number, minScore?: number }} [opts]
     * @returns {Promise<{ name: string, ods: string, score: number }[]>}
     */
    search: async function (nameQuery, opts) {
      opts = opts || {};
      var minLen = typeof opts.minLength === 'number' ? opts.minLength : 2;
      var limit = typeof opts.limit === 'number' ? opts.limit : 8;
      var minScore = typeof opts.minScore === 'number' ? opts.minScore : 45;
      var orgs = await fetchOrgMatches(nameQuery, minLen);
      var ranked = rankOrgs(orgs, nameQuery);
      var out = [];
      for (var i = 0; i < ranked.length && out.length < limit; i++) {
        if (ranked[i].score < minScore) break;
        var o = ranked[i].org;
        out.push({
          name: o.Name || '',
          ods: o.OrgId || '',
          score: ranked[i].score,
        });
      }
      return out;
    },

    /**
     * Single best org for auto-filling ODS (stricter threshold).
     * @param {string} nameQuery
     * @param {{ minLength?: number }} [opts]
     * @returns {Promise<object|null>} raw ORD org or null
     */
    pickBestOrg: async function (nameQuery, opts) {
      opts = opts || {};
      var minLen = typeof opts.minLength === 'number' ? opts.minLength : 3;
      var orgs = await fetchOrgMatches(nameQuery, minLen);
      var q = normQuery(nameQuery);
      if (!orgs.length) return null;
      var best = null;
      var bestS = -Infinity;
      for (var i = 0; i < orgs.length; i++) {
        var org = orgs[i];
        var sc = scoreOrdOrg(org, q);
        if (sc > bestS) {
          bestS = sc;
          best = org;
        }
      }
      if (!best || bestS < 62) return null;
      return best;
    },
  };
})(typeof window !== 'undefined' ? window : this);
