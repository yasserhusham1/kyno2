/**
 * حل التعارضات — للمدراء المتعددين (محلي vs سحابة)
 */
(function (global) {
  'use strict';

  var EMP_FIELDS = [
    { key: 'name', label: 'الاسم' },
    { key: 'dept', label: 'القسم' },
    { key: 'role', label: 'الوظيفة' },
    { key: 'phone', label: 'الهاتف' },
    { key: 'salary', label: 'الراتب' },
    { key: 'salaryType', label: 'نوع الراتب' },
    { key: 'dailyRate', label: 'المعدل اليومي' }
  ];

  var _queue = [];
  var _showing = false;

  function detectEmployeeConflict(local, remote) {
    if (!local || !remote || local.id !== remote.id) return null;
    var diffs = [];
    EMP_FIELDS.forEach(function (f) {
      var lv = local[f.key];
      var rv = remote[f.key];
      if (f.key === 'salary' || f.key === 'dailyRate') {
        lv = parseInt(lv, 10) || 0;
        rv = parseInt(rv, 10) || 0;
      }
      if (String(lv == null ? '' : lv) !== String(rv == null ? '' : rv)) {
        diffs.push({ field: f.key, label: f.label, local: lv, remote: rv });
      }
    });
    return diffs.length ? diffs : null;
  }

  function shouldPromptEmployeeConflict(local, remote, now) {
    if (!local || !remote) return false;
    now = now || Date.now();
    var pending = !!local._pendingRemoteSync;
    var editedRecently = local._localEmpEditAt && (now - local._localEmpEditAt) < 300000;
    if (!pending && !editedRecently) return false;
    if (typeof global.kynoEmployeeSyncHash === 'function' && local._lastCloudSyncHash) {
      var remoteHash = global.kynoEmployeeSyncHash(remote);
      if (remoteHash === local._lastCloudSyncHash) return false;
    }
    return !!detectEmployeeConflict(local, remote);
  }

  function queueConflict(item) {
    var exists = _queue.some(function (x) { return x.type === item.type && x.id === item.id; });
    if (exists) return;
    _queue.push(item);
    global.__basmaConflicts = _queue;
    showNextConflict();
  }

  function applyEmployeeChoice(local, remote, choice, diffs) {
    var out = Object.assign({}, remote);
    if (choice === 'local') {
      return Object.assign(out, local, {
        devices: local.devices || remote.devices,
        _pendingRemoteSync: true,
        _localEmpEditAt: Date.now()
      });
    }
    if (choice === 'remote') {
      delete out._pendingRemoteSync;
      out._lastCloudSyncHash = typeof global.kynoEmployeeSyncHash === 'function'
        ? global.kynoEmployeeSyncHash(out) : undefined;
      return out;
    }
    diffs.forEach(function (d) {
      out[d.field] = local[d.field];
    });
    out._pendingRemoteSync = true;
    out._localEmpEditAt = Date.now();
    return out;
  }

  function showNextConflict() {
    if (_showing || !_queue.length) return;
    if (global.currentUser !== 'admin') return;
    var item = _queue[0];
    _showing = true;
    var rows = item.diffs.map(function (d) {
      return '<tr><td>' + d.label + '</td><td><b>' + (d.local != null ? d.local : '—') + '</b></td><td><b>' + (d.remote != null ? d.remote : '—') + '</b></td></tr>';
    }).join('');
    var title = item.type === 'employee' ? ('تعارض: ' + (item.local.name || item.id)) : 'تعارض بيانات';
    var html = '<p style="font-size:13px;margin-bottom:10px">تم تعديل نفس السجل على جهاز آخر أو في السحابة. اختر النسخة المعتمدة:</p>' +
      '<table style="width:100%;font-size:12px;border-collapse:collapse">' +
      '<tr style="background:rgba(255,255,255,0.05)"><th>الحقل</th><th>نسختك</th><th>السحابة</th></tr>' + rows + '</table>';

    var swalOpts = typeof global.swalTheme === 'function' ? global.swalTheme() : {};

    if (typeof global.Swal === 'undefined') {
      _queue.shift();
      _showing = false;
      return;
    }

    global.Swal.fire({
      title: '⚠️ ' + title,
      html: html,
      icon: 'warning',
      showDenyButton: true,
      showCancelButton: true,
      confirmButtonText: 'اعتمد نسختي',
      denyButtonText: 'اعتمد السحابة',
      cancelButtonText: 'دمج ذكي',
      ...swalOpts
    }).then(function (r) {
      var choice = r.isConfirmed ? 'local' : (r.isDenied ? 'remote' : (r.isDismissed ? 'merge' : 'remote'));
      if (item.type === 'employee') {
        var idx = (global.employees || []).findIndex(function (e) { return e && e.id === item.id; });
        if (idx >= 0) {
          global.employees[idx] = applyEmployeeChoice(item.local, item.remote, choice, item.diffs);
          if (choice === 'local' || choice === 'merge') {
            if (typeof global.persistEmployeeNow === 'function') {
              global.persistEmployeeNow(global.employees[idx]).catch(function () {});
            }
          }
        }
      }
      _queue.shift();
      _showing = false;
      if (typeof global.saveData === 'function') global.saveData();
      if (typeof global.refreshAll === 'function') global.refreshAll();
      setTimeout(showNextConflict, 300);
    });
  }

  global.BasmaConflict = {
    detectEmployeeConflict: detectEmployeeConflict,
    shouldPromptEmployeeConflict: shouldPromptEmployeeConflict,
    queueConflict: queueConflict,
    showNextConflict: showNextConflict
  };
})(typeof window !== 'undefined' ? window : globalThis);
