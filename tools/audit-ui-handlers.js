const fs = require('fs');
const path = require('path');

const html = fs.readFileSync('index.html', 'utf8');
const onclickRe = /onclick="([^"]+)"/g;
const handlers = new Set();
let m;
while ((m = onclickRe.exec(html))) {
  const expr = m[1];
  const fnMatch = expr.match(/^([a-zA-Z_$][\w$]*)\s*\(/);
  if (fnMatch) handlers.add(fnMatch[1]);
}

const jsFiles = [];
function walk(d) {
  for (const f of fs.readdirSync(d)) {
    const p = path.join(d, f);
    if (fs.statSync(p).isDirectory()) walk(p);
    else if (p.endsWith('.js')) jsFiles.push(p);
  }
}
walk('js');
['supabase_integration.js', 'config.js'].forEach((f) => {
  if (fs.existsSync(f)) jsFiles.push(f);
});

const defined = new Set();
const patterns = [
  /(?:^|\n)(?:async\s+)?function\s+([a-zA-Z_$][\w$]*)\s*\(/g,
  /window\.([a-zA-Z_$][\w$]*)\s*=/g,
  /(?:^|\n)([a-zA-Z_$][\w$]*)\s*=\s*(?:async\s+)?function\s*\(/g,
  /(?:^|\n)const\s+([a-zA-Z_$][\w$]*)\s*=\s*(?:async\s+)?(?:function|\()/g,
];

for (const file of jsFiles) {
  const src = fs.readFileSync(file, 'utf8');
  for (const re of patterns) {
    re.lastIndex = 0;
    let mm;
    while ((mm = re.exec(src))) defined.add(mm[1]);
  }
}

const saFromUiExtra = fs.readFileSync('js/app/ui-extra.js', 'utf8');
const saInline = [...saFromUiExtra.matchAll(/onclick="([a-zA-Z_$][\w$]*)\(/g)].map((x) => x[1]);
saInline.forEach((h) => handlers.add(h));

const missing = [...handlers].filter((h) => !defined.has(h)).sort();
console.log('onclick handlers total:', handlers.size);
console.log('MISSING:', missing.length ? missing.join(', ') : 'none');

const uiBindings = fs.readFileSync('js/app/ui-bindings.js', 'utf8');
const saList = uiBindings.match(/SA_HANDLERS = \[([\s\S]*?)\]/);
const coreList = uiBindings.match(/CORE_HANDLERS = \[([\s\S]*?)\]/);
function parseList(block) {
  return [...block.matchAll(/'([^']+)'/g)].map((x) => x[1]);
}
const allAudit = [...parseList(saList[1]), ...parseList(coreList[1])];
const auditMissing = allAudit.filter((n) => !defined.has(n)).sort();
console.log('ui-bindings audit missing:', auditMissing.length ? auditMissing.join(', ') : 'none');
