/**
 * NHS Organisation Directory (ORD) trust name search — shared by staff + profile.
 * https://directory.spineservices.nhs.uk/ORD/2-0-0/organisations
 */
(function (w) {
  var ORD_URL = 'https://directory.spineservices.nhs.uk/ORD/2-0-0/organisations';

  function normQuery(raw) {
    return (raw || '').toLowerCase().replace(/\s+/g, ' ').trim();
  }

  function scoreOrdOrg(org, q) {
    var nm = org.Name || '';
    var name = nm.toLowerCase().replace(/\s+/g, ' ').trim();
    if ((org.Status || '').toUpperCase() !== 'ACTIVE') return -Infinity;
    var s = 0;
    if (/trial|covid|octave|comcov|research database|nhs app/i.test(nm)) s -= 55;
    var rid = org.PrimaryRoleId || '';
    if (rid === 'RO197') s += 100;
    else if (rid === 'RO198') s += 38;
    else if (rid === 'RO76') s += 18;
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
    var url = ORD_URL + '?Name=' + encodeURIComponent(t) + '&Limit=35';
    var res = await fetch(url, { headers: { Accept: 'application/json' } });
    if (!res.ok) return [];
    var data = await res.json();
    return data.Organisations || [];
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
