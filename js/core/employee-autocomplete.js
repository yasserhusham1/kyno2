/**
 * Employee name search with live suggestions
 */
(function (global) {
  'use strict';

  function esc(s) {
    if (global.BasmaSecurity && global.BasmaSecurity.escapeHtml) {
      return global.BasmaSecurity.escapeHtml(String(s || ''));
    }
    return String(s || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/"/g, '&quot;');
  }

  function escAttr(s) {
    return esc(s).replace(/`/g, '&#96;');
  }

  function getEmployeeNameQuery(inputId) {
    var el = document.getElementById(inputId);
    return el ? el.value.trim().toLowerCase() : '';
  }

  function employeeMatchesNameQuery(emp, query) {
    if (!query) return true;
    if (!emp) return false;
    var name = String(emp.name || '').toLowerCase();
    var dept = String(emp.dept || '').toLowerCase();
    return name.indexOf(query) >= 0 || dept.indexOf(query) >= 0;
  }

  function attendanceRecordMatchesNameQuery(record, query, employees) {
    if (!query) return true;
    if (!record) return false;
    var label = String(record.emp || '').toLowerCase();
    if (label.indexOf(query) >= 0) return true;
    var emp = (employees || []).find(function (e) { return e && e.id === record.empId; });
    return employeeMatchesNameQuery(emp, query);
  }

  function getEmployeeSuggestions(query, limit) {
    var q = String(query || '').trim().toLowerCase();
    if (!q) return [];
    var list = global.employees || [];
    var out = [];
    for (var i = 0; i < list.length; i++) {
      var e = list[i];
      if (!e || !employeeMatchesNameQuery(e, q)) continue;
      out.push(e);
      if (out.length >= (limit || 8)) break;
    }
    return out;
  }

  function bindEmployeeNameAutocomplete(inputId, listId, onChange) {
    var input = document.getElementById(inputId);
    var list = document.getElementById(listId);
    if (!input || !list || input.dataset.acBound === '1') return;
    input.dataset.acBound = '1';

    function hideList() {
      list.innerHTML = '';
      list.style.display = 'none';
    }

    function renderList() {
      var q = input.value.trim();
      if (!q) {
        hideList();
        return;
      }
      var suggestions = getEmployeeSuggestions(q, 8);
      if (!suggestions.length) {
        hideList();
        return;
      }
      list.style.display = 'block';
      list.innerHTML = suggestions.map(function (e) {
        return '<button type="button" class="name-ac-item" data-name="' + escAttr(e.name) + '">' +
          '<span class="name-ac-item-title">' + esc(e.name) + '</span>' +
          '<span class="name-ac-item-meta">' + esc(e.dept || '') + '</span>' +
          '</button>';
      }).join('');
    }

    function notifyChange() {
      if (typeof onChange === 'function') onChange();
    }

    input.addEventListener('input', function () {
      renderList();
      notifyChange();
    });

    input.addEventListener('focus', renderList);

    input.addEventListener('keydown', function (ev) {
      if (ev.key === 'Escape') hideList();
    });

    list.addEventListener('mousedown', function (ev) {
      ev.preventDefault();
    });

    list.addEventListener('click', function (ev) {
      var btn = ev.target.closest('.name-ac-item');
      if (!btn) return;
      input.value = btn.getAttribute('data-name') || '';
      hideList();
      notifyChange();
    });

    document.addEventListener('click', function (ev) {
      if (ev.target === input || list.contains(ev.target)) return;
      hideList();
    });
  }

  function initEmployeeNameFilters() {
    bindEmployeeNameAutocomplete('att-filter-name', 'att-filter-name-list', function () {
      if (typeof global.buildAttendance === 'function') global.buildAttendance();
    });
    bindEmployeeNameAutocomplete('sal-filter-name', 'sal-filter-name-list', function () {
      if (typeof global.buildSalaries === 'function') global.buildSalaries();
    });
  }

  global.getEmployeeNameQuery = getEmployeeNameQuery;
  global.employeeMatchesNameQuery = employeeMatchesNameQuery;
  global.attendanceRecordMatchesNameQuery = attendanceRecordMatchesNameQuery;
  global.bindEmployeeNameAutocomplete = bindEmployeeNameAutocomplete;
  global.initEmployeeNameFilters = initEmployeeNameFilters;

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initEmployeeNameFilters);
  } else {
    initEmployeeNameFilters();
  }
})(typeof window !== 'undefined' ? window : globalThis);
