/**
 * تنسيق الوقت الموحد — 12/24 ساعة حسب إعدادات الشركة
 */
(function (global) {
  'use strict';

  var APP_TIMEZONE = 'Asia/Baghdad';

  function use24HourClock() {
    return !!(global.appSettings && global.appSettings.clockFormat === '24');
  }

  function parseTimeParts(timeStr) {
    if (!timeStr || timeStr === '—') return null;
    var s = String(timeStr).trim();
    var ampmMatch = s.match(/^(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(AM|PM)?$/i);
    if (ampmMatch) {
      var h = parseInt(ampmMatch[1], 10);
      var m = parseInt(ampmMatch[2], 10);
      var sec = parseInt(ampmMatch[3] || '0', 10);
      var ap = (ampmMatch[4] || '').toUpperCase();
      if (ap === 'PM' && h !== 12) h += 12;
      if (ap === 'AM' && h === 12) h = 0;
      if (!ap && h >= 0 && h <= 23) { /* already 24h */ }
      else if (!ap && h >= 1 && h <= 12) { /* ambiguous — treat as 24 if clock is 24 */ }
      return { h: h, m: m, s: sec };
    }
    var hm = s.match(/^(\d{1,2}):(\d{2})$/);
    if (hm) {
      return { h: parseInt(hm[1], 10), m: parseInt(hm[2], 10), s: 0 };
    }
    return null;
  }

  function timeToMinutes(timeStr) {
    var p = parseTimeParts(timeStr);
    if (!p) return 0;
    return p.h * 60 + p.m;
  }

  function formatFromParts(h, m, s, use24, withSeconds) {
    h = Math.max(0, Math.min(23, parseInt(h, 10) || 0));
    m = Math.max(0, Math.min(59, parseInt(m, 10) || 0));
    s = Math.max(0, Math.min(59, parseInt(s, 10) || 0));
    if (use24) {
      var out = String(h).padStart(2, '0') + ':' + String(m).padStart(2, '0');
      if (withSeconds) out += ':' + String(s).padStart(2, '0');
      return out;
    }
    var ap = h >= 12 ? 'PM' : 'AM';
    var h12 = h % 12;
    if (h12 === 0) h12 = 12;
    var line = String(h12).padStart(2, '0') + ':' + String(m).padStart(2, '0');
    if (withSeconds) line += ':' + String(s).padStart(2, '0');
    return line + ' ' + ap;
  }

  function convertTimeString(timeStr, to24) {
    if (!timeStr || timeStr === '—') return timeStr;
    var p = parseTimeParts(timeStr);
    if (!p) return timeStr;
    return formatFromParts(p.h, p.m, p.s, !!to24, String(timeStr).indexOf(':') >= 0 && /:\d{2}:\d{2}/.test(String(timeStr)));
  }

  function formatDisplayTime(timeStr, withSeconds) {
    if (!timeStr || timeStr === '—') return '—';
    var p = parseTimeParts(timeStr);
    if (!p) return String(timeStr);
    return formatFromParts(p.h, p.m, p.s, use24HourClock(), withSeconds);
  }

  function formatDateClock(date, withSeconds) {
    date = date || new Date();
    var parts = new Intl.DateTimeFormat('en-US', {
      timeZone: APP_TIMEZONE,
      hour: 'numeric',
      minute: '2-digit',
      second: withSeconds ? '2-digit' : undefined,
      hour12: !use24HourClock()
    }).formatToParts(date);
    var map = {};
    parts.forEach(function (p) { map[p.type] = p.value; });
    var h = parseInt(map.hour, 10);
    var m = parseInt(map.minute, 10);
    var s = withSeconds ? parseInt(map.second || '0', 10) : 0;
    if (!use24HourClock()) {
      var ap = (map.dayPeriod || '').toUpperCase();
      if (ap === 'PM' && h !== 12) h += 12;
      if (ap === 'AM' && h === 12) h = 0;
    }
    return formatFromParts(h, m, s, use24HourClock(), withSeconds);
  }

  function migrateAllTimesToClockFormat(targetFormat) {
    var to24 = targetFormat === '24';
    (global.employees || []).forEach(function (e) {
      if (!e) return;
      if (e.checkIn) e.checkIn = convertTimeString(e.checkIn, to24);
      if (e.checkOut) e.checkOut = convertTimeString(e.checkOut, to24);
    });
    (global.attData || []).forEach(function (r) {
      if (!r) return;
      if (r.ci && r.ci !== '—') r.ci = convertTimeString(r.ci, to24);
      if (r.co && r.co !== '—') r.co = convertTimeString(r.co, to24);
    });
  }

  global.BasmaTime = {
    APP_TIMEZONE: APP_TIMEZONE,
    use24HourClock: use24HourClock,
    parseTimeParts: parseTimeParts,
    timeToMinutes: timeToMinutes,
    formatFromParts: formatFromParts,
    convertTimeString: convertTimeString,
    formatDisplayTime: formatDisplayTime,
    formatDateClock: formatDateClock,
    migrateAllTimesToClockFormat: migrateAllTimesToClockFormat
  };

  global.timeToMinutes = timeToMinutes;
  global.formatDisplayTime = formatDisplayTime;
  global.formatDateClock = formatDateClock;
})(typeof window !== 'undefined' ? window : globalThis);
