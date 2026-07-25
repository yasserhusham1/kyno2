/**
 * بيانات وألوان الرسوم البيانية — حضور فعلي + دعم الوضع الداكن/الفاتح
 */
(function (global) {
  'use strict';

  var DAY_NAMES = ['الأحد', 'الاثنين', 'الثلاثاء', 'الأربعاء', 'الخميس', 'الجمعة', 'السبت'];

  function getAttRecordDateIso(rec) {
    if (!rec) return '';
    var iso = rec.dateIso || rec.date_iso || '';
    if (iso) return String(iso).slice(0, 10);
    return '';
  }

  function isLeaveOnDate(leave, iso) {
    if (!leave || !leave.fromDate || !iso) return false;
    var t = new Date(iso + 'T12:00:00');
    var from = new Date(String(leave.fromDate).slice(0, 10) + 'T00:00:00');
    var toRaw = leave.toDate || leave.fromDate;
    var to = new Date(String(toRaw).slice(0, 10) + 'T23:59:59');
    return t >= from && t <= to;
  }

  function isAttPresent(rec) {
    if (!rec) return false;
    if (rec.status === 'غياب' || rec.ci === '—') return false;
    return rec.status === 'طبيعي' || rec.status === 'إضافي' || rec.status === 'متأخر';
  }

  function isAttAbsent(rec) {
    if (!rec) return false;
    return rec.status === 'غياب' || rec.ci === '—';
  }

  function getChartThemeColors() {
    var light = global.document && global.document.documentElement.getAttribute('data-theme') === 'light';
    return {
      text: light ? '#1a202c' : '#e8f4fd',
      textMuted: light ? '#718096' : '#a0aec0',
      grid: light ? 'rgba(0,0,0,0.08)' : 'rgba(255,255,255,0.06)',
      present: light ? 'rgba(0,168,128,0.82)' : 'rgba(0,212,170,0.75)',
      absent: light ? 'rgba(229,62,62,0.62)' : 'rgba(229,62,62,0.55)',
      late: light ? 'rgba(214,158,46,0.82)' : 'rgba(244,161,0,0.75)',
      leave: light ? 'rgba(49,130,206,0.72)' : 'rgba(49,130,206,0.68)',
      accent: light ? '#00a880' : '#00d4aa',
      accentFill: light ? 'rgba(0,168,128,0.14)' : 'rgba(0,212,170,0.12)',
      deptBar: light ? 'rgba(0,168,128,0.58)' : 'rgba(0,212,170,0.62)',
      listDivider: light ? 'rgba(0,0,0,0.07)' : 'rgba(255,255,255,0.06)'
    };
  }

  function baseChartOptions(theme, extra) {
    extra = extra || {};
    return {
      responsive: true,
      maintainAspectRatio: true,
      plugins: {
        legend: {
          labels: {
            color: theme.text,
            font: { family: 'Cairo, sans-serif' },
            padding: extra.legendPadding || 12
          }
        }
      },
      scales: extra.scales || {}
    };
  }

  function computeWeeklyAttendanceStats(attData) {
    var days = [];
    var now = new Date();
    for (var i = 6; i >= 0; i--) {
      var d = new Date(now.getFullYear(), now.getMonth(), now.getDate() - i);
      var iso =
        d.getFullYear() +
        '-' +
        String(d.getMonth() + 1).padStart(2, '0') +
        '-' +
        String(d.getDate()).padStart(2, '0');
      days.push({ iso: iso, label: DAY_NAMES[d.getDay()] });
    }
    var present = days.map(function () { return 0; });
    var absent = days.map(function () { return 0; });
    var presentSeen = days.map(function () { return {}; });
    var absentSeen = days.map(function () { return {}; });
    (attData || []).forEach(function (rec) {
      var iso = getAttRecordDateIso(rec);
      var idx = days.findIndex(function (d) { return d.iso === iso; });
      if (idx < 0) return;
      var k = attEmpDayKey(rec);
      if (!k) return;
      if (isAttAbsent(rec)) {
        if (!absentSeen[idx][k]) {
          absentSeen[idx][k] = true;
          absent[idx]++;
        }
      } else if (isAttPresent(rec)) {
        if (!presentSeen[idx][k]) {
          presentSeen[idx][k] = true;
          present[idx]++;
        }
      }
    });
    return {
      labels: days.map(function (d) { return d.label; }),
      present: present,
      absent: absent
    };
  }

  function computeTodayAttendanceBreakdown(attData, employees, leavesData, todayIso) {
    todayIso = todayIso || (typeof global.todayIsoDate === 'function' ? global.todayIsoDate() : '');
    var totalEmp = (employees || []).length;
    var onTime = 0;
    var late = 0;
    var absent = 0;
    var seen = {};
    (attData || []).forEach(function (r) {
      if (getAttRecordDateIso(r) !== todayIso) return;
      var k = attEmpDayKey(r);
      if (!k || seen[k]) return;
      seen[k] = true;
      if (r.status === 'طبيعي' || r.status === 'إضافي') onTime++;
      else if (r.status === 'متأخر') late++;
      else if (isAttAbsent(r)) absent++;
    });
    var recordedIds = {};
    Object.keys(seen).forEach(function (k) {
      var empId = parseInt(k.split('|')[0], 10);
      if (empId) recordedIds[empId] = true;
    });
    var onLeave = 0;
    (employees || []).forEach(function (emp) {
      if (!emp || recordedIds[emp.id]) return;
      var hasLeave = (leavesData || []).some(function (l) {
        return l && String(l.empId) === String(emp.id) && isLeaveOnDate(l, todayIso);
      });
      if (hasLeave) onLeave++;
    });
    var remainder = Math.max(0, totalEmp - onTime - late - absent - onLeave);
    return {
      labels: ['حاضر', 'غائب', 'متأخر', 'إجازة'],
      data: [onTime, absent, late, onLeave + remainder]
    };
  }

  function attEmpDayKey(rec) {
    if (!rec || !rec.empId) return '';
    var iso = getAttRecordDateIso(rec);
    return iso ? String(rec.empId) + '|' + iso : '';
  }

  function computeMonthlyAttendanceRates(attData, employees) {
    var now = new Date();
    var year = now.getFullYear();
    var month = now.getMonth();
    var daysInMonth = new Date(year, month + 1, 0).getDate();
    var totalEmp = Math.max(1, (employees || []).length);
    var labels = [];
    var rates = [];
    for (var day = 1; day <= daysInMonth; day++) {
      var iso =
        year +
        '-' +
        String(month + 1).padStart(2, '0') +
        '-' +
        String(day).padStart(2, '0');
      labels.push(String(day));
      var presentSet = {};
      (attData || []).forEach(function (r) {
        if (getAttRecordDateIso(r) !== iso) return;
        if (!r.ci || r.ci === '—' || r.status === 'غياب') return;
        var k = attEmpDayKey(r);
        if (k) presentSet[k] = true;
      });
      var present = Object.keys(presentSet).length;
      rates.push(Math.min(100, Math.round((present / totalEmp) * 100)));
    }
    return { labels: labels, rates: rates };
  }

  function computeDepartmentAttendanceRates(attData, employees) {
    var now = new Date();
    var year = now.getFullYear();
    var month = now.getMonth();
    var daysElapsed = Math.max(1, now.getDate());
    var deptMap = {};
    (employees || []).forEach(function (emp) {
      if (!emp || !emp.dept) return;
      if (!deptMap[emp.dept]) deptMap[emp.dept] = { count: 0, presentKeys: {} };
      deptMap[emp.dept].count++;
    });
    (attData || []).forEach(function (rec) {
      var iso = getAttRecordDateIso(rec);
      if (!iso) return;
      var d = new Date(iso + 'T12:00:00');
      if (d.getFullYear() !== year || d.getMonth() !== month) return;
      if (!rec.ci || rec.ci === '—' || rec.status === 'غياب') return;
      var emp = (employees || []).find(function (e) { return e && e.id === rec.empId; });
      if (!emp || !emp.dept || !deptMap[emp.dept]) return;
      var k = attEmpDayKey(rec);
      if (k) deptMap[emp.dept].presentKeys[k] = true;
    });
    var labels = Object.keys(deptMap).sort(function (a, b) {
      return Object.keys(deptMap[b].presentKeys).length - Object.keys(deptMap[a].presentKeys).length;
    });
    if (!labels.length) {
      labels = ['—'];
      return { labels: labels, rates: [0] };
    }
    var rates = labels.map(function (dept) {
      var info = deptMap[dept];
      var possible = info.count * daysElapsed;
      var present = Object.keys(info.presentKeys).length;
      return possible > 0 ? Math.min(100, Math.round((present / possible) * 100)) : 0;
    });
    return { labels: labels, rates: rates };
  }

  function computeTopCommittedEmployees(employees, attData, limit) {
    limit = limit || 5;
    var now = new Date();
    var year = now.getFullYear();
    var month = now.getMonth();
    var daysElapsed = Math.max(1, now.getDate());
    var rows = (employees || []).map(function (emp) {
      var dayKeys = {};
      var lateCount = 0;
      var lateSeen = {};
      (attData || []).forEach(function (rec) {
        if (!rec || rec.empId !== emp.id) return;
        var iso = getAttRecordDateIso(rec);
        if (!iso) return;
        var d = new Date(iso + 'T12:00:00');
        if (d.getFullYear() !== year || d.getMonth() !== month) return;
        var k = attEmpDayKey(rec);
        if (!k) return;
        if (rec.ci && rec.ci !== '—' && rec.status !== 'غياب') dayKeys[k] = true;
        if (rec.status === 'متأخر' && !lateSeen[k]) {
          lateSeen[k] = true;
          lateCount++;
        }
      });
      var presentDays = Object.keys(dayKeys).length;
      return {
        emp: emp,
        presentDays: presentDays,
        lateCount: lateCount,
        score: presentDays * 10 - lateCount * 2
      };
    });
    rows.sort(function (a, b) {
      if (b.score !== a.score) return b.score - a.score;
      if (b.presentDays !== a.presentDays) return b.presentDays - a.presentDays;
      return String(a.emp.name || '').localeCompare(String(b.emp.name || ''), 'ar');
    });
    return rows.slice(0, limit).map(function (row) {
      return Object.assign({}, row, {
        progress: Math.min(100, Math.round((row.presentDays / daysElapsed) * 100))
      });
    });
  }

  function renderChart(key, canvasId, config) {
    function draw() {
      if (!global.Chart) return null;
      var ctx = global.document && global.document.getElementById(canvasId);
      if (!ctx) return null;
      global.charts = global.charts || {};
      if (global.charts[key]) {
        try { global.charts[key].destroy(); } catch (e) { /* ignore */ }
      }
      global.charts[key] = new global.Chart(ctx, config);
      return global.charts[key];
    }
    if (global.Chart) return draw();
    if (typeof global.ensureChartLoaded === 'function') {
      global.ensureChartLoaded().then(draw).catch(function (e) {
        console.warn('renderChart:', e);
      });
      return null;
    }
    return null;
  }

  function buildWeekChart(attData) {
    var theme = getChartThemeColors();
    var stats = computeWeeklyAttendanceStats(attData);
    return renderChart('week', 'weekChart', {
      type: 'bar',
      data: {
        labels: stats.labels,
        datasets: [
          { label: 'حاضر', data: stats.present, backgroundColor: theme.present, borderRadius: 8 },
          { label: 'غائب', data: stats.absent, backgroundColor: theme.absent, borderRadius: 8 }
        ]
      },
      options: Object.assign(baseChartOptions(theme), {
        scales: {
          x: { ticks: { color: theme.textMuted, font: { family: 'Cairo' } }, grid: { display: false } },
          y: {
            ticks: { color: theme.textMuted, font: { family: 'Cairo' }, precision: 0 },
            grid: { color: theme.grid },
            beginAtZero: true
          }
        }
      })
    });
  }

  function buildTodayChart(attData, employees, leavesData) {
    var theme = getChartThemeColors();
    var stats = computeTodayAttendanceBreakdown(attData, employees, leavesData);
    return renderChart('today', 'todayChart', {
      type: 'doughnut',
      data: {
        labels: stats.labels,
        datasets: [{
          data: stats.data,
          backgroundColor: [theme.present, theme.absent, theme.late, theme.leave],
          borderWidth: 0,
          hoverOffset: 8
        }]
      },
      options: {
        responsive: true,
        plugins: {
          legend: {
            position: 'bottom',
            labels: {
              color: theme.text,
              font: { family: 'Cairo, sans-serif' },
              padding: 14
            }
          }
        }
      }
    });
  }

  function buildMonthChart(attData, employees) {
    var theme = getChartThemeColors();
    var stats = computeMonthlyAttendanceRates(attData, employees);
    var maxRate = Math.max.apply(null, stats.rates.concat([100]));
    return renderChart('month', 'monthChart', {
      type: 'line',
      data: {
        labels: stats.labels,
        datasets: [{
          label: 'معدل الحضور %',
          data: stats.rates,
          borderColor: theme.accent,
          backgroundColor: theme.accentFill,
          tension: 0.35,
          fill: true,
          pointBackgroundColor: theme.accent,
          pointRadius: 3
        }]
      },
      options: Object.assign(baseChartOptions(theme), {
        scales: {
          x: {
            ticks: { color: theme.textMuted, font: { family: 'Cairo' }, maxTicksLimit: 16 },
            grid: { color: theme.grid }
          },
          y: {
            ticks: { color: theme.textMuted, font: { family: 'Cairo' } },
            grid: { color: theme.grid },
            min: 0,
            max: Math.max(100, maxRate)
          }
        }
      })
    });
  }

  function buildDeptChart(attData, employees) {
    var theme = getChartThemeColors();
    var stats = computeDepartmentAttendanceRates(attData, employees);
    return renderChart('dept', 'deptChart', {
      type: 'bar',
      data: {
        labels: stats.labels,
        datasets: [{
          label: 'معدل الحضور %',
          data: stats.rates,
          backgroundColor: theme.deptBar,
          borderRadius: 8
        }]
      },
      options: {
        responsive: true,
        indexAxis: 'y',
        plugins: { legend: { display: false } },
        scales: {
          x: {
            ticks: { color: theme.textMuted, font: { family: 'Cairo' } },
            grid: { color: theme.grid },
            min: 0,
            max: 100
          },
          y: {
            ticks: { color: theme.text, font: { family: 'Cairo' } },
            grid: { display: false }
          }
        }
      }
    });
  }

  global.BasmaCharts = {
    getChartThemeColors: getChartThemeColors,
    computeWeeklyAttendanceStats: computeWeeklyAttendanceStats,
    computeTodayAttendanceBreakdown: computeTodayAttendanceBreakdown,
    computeMonthlyAttendanceRates: computeMonthlyAttendanceRates,
    computeDepartmentAttendanceRates: computeDepartmentAttendanceRates,
    computeTopCommittedEmployees: computeTopCommittedEmployees,
    renderChart: renderChart,
    buildWeekChart: buildWeekChart,
    buildTodayChart: buildTodayChart,
    buildMonthChart: buildMonthChart,
    buildDeptChart: buildDeptChart
  };
})(typeof window !== 'undefined' ? window : globalThis);
