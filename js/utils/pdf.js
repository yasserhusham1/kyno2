/**
 * PDF generation — Blob URLs, font loading, Arabic support
 */
(function (global) {
  'use strict';

  async function waitForFonts() {
    if (document.fonts && document.fonts.ready) {
      try { await document.fonts.ready; } catch (e) {}
    }
    await new Promise(function (r) { setTimeout(r, 120); });
  }

  function saveCanvasAsPdf(canvas, filename, orientation) {
    if (!canvas || !canvas.width || !canvas.height) {
      throw new Error('Canvas فارغ — لا يمكن إنشاء PDF');
    }
    var jsPDF = global.jspdf && global.jspdf.jsPDF;
    if (!jsPDF) throw new Error('مكتبة jsPDF غير جاهزة');
    var dir = orientation === 'landscape' ? 'l' : 'p';
    var pdf = new jsPDF({ orientation: dir, unit: 'mm', format: 'a4' });
    var pageW = pdf.internal.pageSize.getWidth();
    var pageH = pdf.internal.pageSize.getHeight();
    var imgData = canvas.toDataURL('image/jpeg', 0.92);
    var ratio = Math.min(pageW / canvas.width, pageH / canvas.height);
    var w = canvas.width * ratio;
    var h = canvas.height * ratio;
    pdf.addImage(imgData, 'JPEG', (pageW - w) / 2, 8, w, h);
    var safeName = global.BasmaSecurity ? BasmaSecurity.sanitizeFilename(filename) : (filename || 'report.pdf');
    pdf.save(safeName.endsWith('.pdf') ? safeName : safeName + '.pdf');
  }

  async function captureHtmlToCanvas(html, width) {
    if (typeof html2canvas === 'undefined') throw new Error('html2canvas غير جاهز');
    await waitForFonts();
    var iframe = document.createElement('iframe');
    iframe.style.cssText = 'position:fixed;left:-9999px;top:0;width:' + (width || 794) + 'px;height:10px;border:0';
    document.body.appendChild(iframe);
    var doc = iframe.contentDocument || iframe.contentWindow.document;
    doc.open();
    doc.write('<!DOCTYPE html><html dir="rtl" lang="ar"><head><meta charset="UTF-8">');
    doc.write('<link href="https://fonts.googleapis.com/css2?family=Cairo:wght@400;700&family=Tajawal:wght@400;700&display=swap" rel="stylesheet">');
    doc.write('<style>body{font-family:Cairo,Tajawal,sans-serif;margin:16px;background:#fff;color:#111;font-size:13px}table{width:100%;border-collapse:collapse}th,td{border:1px solid #ccc;padding:6px;text-align:right}</style></head><body>');
    doc.write(html);
    doc.write('</body></html>');
    doc.close();
    await waitForFonts();
    await new Promise(function (r) { setTimeout(r, 200); });
    var body = doc.body;
    iframe.style.height = body.scrollHeight + 40 + 'px';
    var canvas = await html2canvas(body, {
      scale: 2,
      useCORS: true,
      allowTaint: false,
      backgroundColor: '#ffffff',
      logging: false
    });
    document.body.removeChild(iframe);
    if (!canvas || canvas.width < 10) throw new Error('فشل التقاط محتوى PDF');
    return canvas;
  }

  async function downloadPdfFromHtml(html, filename, orientation) {
    var canvas = await captureHtmlToCanvas(html);
    saveCanvasAsPdf(canvas, filename, orientation);
    if (global.URL && global.URL.revokeObjectURL) {
      /* blob path used inside jsPDF save */
    }
  }

  global.BasmaPdf = {
    waitForFonts: waitForFonts,
    saveCanvasAsPdf: saveCanvasAsPdf,
    captureHtmlToCanvas: captureHtmlToCanvas,
    downloadPdfFromHtml: downloadPdfFromHtml
  };
})(typeof window !== 'undefined' ? window : globalThis);
