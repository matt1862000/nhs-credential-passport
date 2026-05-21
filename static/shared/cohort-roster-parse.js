/**
 * Parse HR cohort roster from CSV, plain text, or Excel (.xlsx / .xls).
 * Expected columns (in order): full name, GMC number, personal email.
 * Header row is recommended (e.g. Full Name, GMC Number, Personal Email).
 */
(function (global) {
  var EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

  var FIELD_ALIASES = {
    personal_email: [
      'personal_email',
      'personal',
      'personal_e_mail',
      'login_email',
      'home_email',
      'private_email',
      'email_address',
    ],
    display_name: [
      'display_name',
      'full_name',
      'fullname',
      'name',
      'doctor_name',
      'clinician_name',
      'clinician',
    ],
    gmc_number: ['gmc_number', 'gmc', 'gmc_no', 'gmcno', 'gmc_number_'],
  };

  function normalizeHeader(cell) {
    return String(cell || '')
      .trim()
      .toLowerCase()
      .replace(/[^\w]+/g, '_')
      .replace(/^_+|_+$/g, '');
  }

  function parseCsvRow(line) {
    var out = [];
    var cur = '';
    var inQuotes = false;
    for (var i = 0; i < line.length; i++) {
      var ch = line.charAt(i);
      if (ch === '"') {
        if (inQuotes && line.charAt(i + 1) === '"') {
          cur += '"';
          i += 1;
        } else {
          inQuotes = !inQuotes;
        }
        continue;
      }
      if (!inQuotes && ch === ',') {
        out.push(cur.trim());
        cur = '';
        continue;
      }
      if (!inQuotes && ch === '\t') {
        out.push(cur.trim());
        cur = '';
        continue;
      }
      cur += ch;
    }
    out.push(cur.trim());
    return out.map(function (c) {
      return c.replace(/^["']|["']$/g, '').trim();
    });
  }

  function fieldIndexForHeader(normHeader, field) {
    var aliases = FIELD_ALIASES[field] || [];
    var i;
    for (i = 0; i < aliases.length; i++) {
      if (normHeader === aliases[i]) return true;
    }
    if (field === 'personal_email') {
      if (normHeader === 'email' || normHeader === 'e_mail') return true;
      if (normHeader.indexOf('personal') >= 0 && normHeader.indexOf('email') >= 0) return true;
      if (normHeader.indexOf('login') >= 0 && normHeader.indexOf('email') >= 0) return true;
    }
    return false;
  }

  function mapHeaders(cols) {
    var map = { personal_email: -1, display_name: -1, gmc_number: -1 };
    cols.forEach(function (cell, idx) {
      var h = normalizeHeader(cell);
      if (!h) return;
      Object.keys(map).forEach(function (field) {
        if (fieldIndexForHeader(h, field)) {
          map[field] = idx;
        }
      });
    });
    return map.personal_email >= 0 ? map : null;
  }

  function looksLikeHeader(cols) {
    return !!mapHeaders(cols);
  }

  function cellAt(cols, idx) {
    if (idx < 0 || idx >= cols.length) return '';
    return String(cols[idx] || '').trim();
  }

  function normalizeGmc(raw) {
    var g = String(raw || '').replace(/\D/g, '');
    return g.length === 7 ? g : '';
  }

  function rowToMember(cols, headerMap) {
    var personal = '';
    var dn = '';
    var gmc = '';

    if (headerMap) {
      personal = cellAt(cols, headerMap.personal_email).toLowerCase();
      dn = cellAt(cols, headerMap.display_name);
      gmc = normalizeGmc(cellAt(cols, headerMap.gmc_number));
    } else if (cols.length >= 3) {
      dn = cellAt(cols, 0);
      gmc = normalizeGmc(cellAt(cols, 1));
      personal = cellAt(cols, 2).toLowerCase();
    } else if (cols.length === 2) {
      if (EMAIL_RE.test(cellAt(cols, 1))) {
        dn = cellAt(cols, 0);
        personal = cellAt(cols, 1).toLowerCase();
      } else if (EMAIL_RE.test(cellAt(cols, 0))) {
        personal = cellAt(cols, 0).toLowerCase();
        dn = cellAt(cols, 1);
      }
    } else if (cols.length === 1) {
      var first = cellAt(cols, 0);
      if (EMAIL_RE.test(first)) personal = first.toLowerCase();
    }

    if (!EMAIL_RE.test(personal)) return null;
    var member = { personal_email: personal };
    if (dn) member.display_name = dn;
    if (gmc) member.gmc_number = gmc;
    return member;
  }

  function cellValue(v) {
    if (v == null) return '';
    return String(v).trim();
  }

  function rowHasContent(cols) {
    return cols.some(function (c) {
      return !!cellValue(c);
    });
  }

  function parseRosterRows(rows) {
    var members = [];
    var headerMap = null;
    var seen = Object.create(null);

    (rows || []).forEach(function (rawRow) {
      if (!rawRow || !rawRow.length) return;
      var cols = rawRow.map(cellValue);
      if (!rowHasContent(cols)) return;
      if (!headerMap && looksLikeHeader(cols)) {
        headerMap = mapHeaders(cols);
        return;
      }
      var m = rowToMember(cols, headerMap);
      if (!m || seen[m.personal_email]) return;
      seen[m.personal_email] = true;
      members.push(m);
    });
    return members;
  }

  function parseRosterText(text) {
    var lines = String(text || '').split(/\r?\n/);
    var rows = [];
    lines.forEach(function (rawLine) {
      var line = rawLine.trim();
      if (!line || line.charAt(0) === '#') return;
      rows.push(parseCsvRow(line));
    });
    return parseRosterRows(rows);
  }

  function isExcelFile(file) {
    if (!file) return false;
    var name = String(file.name || '').toLowerCase();
    var type = String(file.type || '').toLowerCase();
    if (name.endsWith('.xlsx') || name.endsWith('.xlsm') || name.endsWith('.xls')) return true;
    if (
      type.indexOf('spreadsheetml') >= 0 ||
      type === 'application/vnd.ms-excel' ||
      type === 'application/vnd.ms-excel.sheet.macroenabled.12'
    ) {
      return true;
    }
    return false;
  }

  function parseExcelArrayBuffer(buf) {
    if (!global.XLSX || typeof global.XLSX.read !== 'function') {
      throw new Error('Excel support is not available. Save the file as CSV and try again.');
    }
    var wb = global.XLSX.read(buf, { type: 'array' });
    if (!wb.SheetNames || !wb.SheetNames.length) {
      return [];
    }
    var sheet = wb.Sheets[wb.SheetNames[0]];
    var rows = global.XLSX.utils.sheet_to_json(sheet, {
      header: 1,
      defval: '',
      raw: false,
    });
    return parseRosterRows(rows);
  }

  function parseRosterFile(file) {
    return new Promise(function (resolve, reject) {
      if (!file) {
        reject(new Error('No file selected'));
        return;
      }
      var reader = new FileReader();
      reader.onerror = function () {
        reject(new Error('Could not read that file'));
      };
      if (isExcelFile(file)) {
        reader.onload = function () {
          try {
            resolve(parseExcelArrayBuffer(reader.result));
          } catch (e) {
            reject(e);
          }
        };
        reader.readAsArrayBuffer(file);
        return;
      }
      reader.onload = function () {
        try {
          resolve(parseRosterText(reader.result));
        } catch (e) {
          reject(e);
        }
      };
      reader.readAsText(file);
    });
  }

  function mergeMember(into, from) {
    if (from.display_name && !into.display_name) into.display_name = from.display_name;
    if (from.gmc_number && !into.gmc_number) into.gmc_number = from.gmc_number;
  }

  global.NHSCohortRosterParse = {
    parseRosterText: parseRosterText,
    parseRosterRows: parseRosterRows,
    parseRosterFile: parseRosterFile,
    isExcelFile: isExcelFile,
    isValidEmail: function (s) {
      return EMAIL_RE.test(String(s || '').trim());
    },
    mergeMember: mergeMember,
  };
})(typeof window !== 'undefined' ? window : globalThis);
