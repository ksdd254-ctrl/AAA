// Adds a tweak pack (a folder of .reg / .bat / .cmd files) to the app's library, as text only - nothing in it is run.
//   node tools\import-pack.js "<pack folder>" "<pack name>"
// - registry values ("reg add" lines and .reg files) become library settings; a value the library already has
//   is counted once more (and its data added as one more option), a new one becomes a new setting
// - sc / schtasks / netsh / powershell lines become library commands
// New entries are filed under "advanced": the app routes each to its own section by what it changes, and the
// app's own rules (danger, junk, protection, safe services, duplicates, conflicts) decide what is kept.
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const packDir = process.argv[2];
const packName = process.argv[3] || path.basename(packDir);
const libFile = path.join(__dirname, '..', 'JdoTweak', 'Data', 'library.tsv.gz');
// tools, drivers, installers and things the app never does (BIOS, activation, unsigned polling driver)
const SKIP = /hidusbf|scewin|activation|snappy driver|easybcd|monitoring|rw-everything|install_programs|restore_configs|radeon software slimmer|\\browser\\|\\modules\\idle\\|take ?ownership|reboot to bios|silentsetup|\\support\\/i;

const HIVES = { HKLM: 'HKEY_LOCAL_MACHINE', HKCU: 'HKEY_CURRENT_USER', HKCR: 'HKEY_CLASSES_ROOT', HKU: 'HKEY_USERS', HKCC: 'HKEY_CURRENT_CONFIG' };
const fullKey = (k) => { k = k.trim().replace(/^"|"$/g, '').replace(/\\+$/, ''); const i = k.indexOf('\\'); const h = (i < 0 ? k : k.slice(0, i)).toUpperCase(); return (HIVES[h] || h) + (i < 0 ? '' : k.slice(i)); };

const settings = [];   // { key, name, type, data }
const commands = [];   // { kind, text }

function readText(f) {
  const b = fs.readFileSync(f);
  if (b[0] === 0xff && b[1] === 0xfe) return b.toString('utf16le').slice(1);
  return b.toString('utf8').replace(/^\uFEFF/, '');
}

// ---------- "reg add" lines
function regAdd(line) {
  const toks = line.match(/"[^"]*"|\S+/g) || [];
  if (toks.length < 3 || !/^reg(\.exe)?$/i.test(toks[0]) || !/^add$/i.test(toks[1])) return;
  const key = fullKey(toks[2]);
  let name = null, type = 'REG_SZ', data = '', hasD = false;
  for (let i = 3; i < toks.length; i++) {
    const t = toks[i].toLowerCase(), v = (toks[i + 1] || '').replace(/^"|"$/g, '');
    if (t === '/v') { name = v; i++; } else if (t === '/ve') { name = ''; } else if (t === '/t') { type = v.toUpperCase(); i++; } else if (t === '/d') { data = v; hasD = true; i++; }
  }
  if (name === null) return;   // creates a key only
  if (/%|!/.test(key + name)) return;
  const map = { REG_DWORD: 'dw', REG_QWORD: 'qw', REG_SZ: 'sz', REG_EXPAND_SZ: 'esz', REG_MULTI_SZ: 'msz', REG_BINARY: 'bin' };
  const tt = map[type]; if (!tt) return;
  let d = data;
  if (tt === 'dw' || tt === 'qw') { if (!hasD) return; const n = /^0x/i.test(d) ? parseInt(d, 16) : Number(d); if (!Number.isFinite(n) || n < 0) return; d = String(n); }
  if (tt === 'bin') d = (d.match(/../g) || []).join(',').toLowerCase();
  if (tt === 'msz') d = d.split('\\0').join('\x1E');
  settings.push({ key, name, type: tt, data: d });
}

// ---------- .reg files
function regFile(text) {
  const lines = text.replace(/\\\r?\n\s*/g, '').split(/\r?\n/);
  let key = null, del = false;
  for (const l of lines) {
    const k = l.match(/^\[(-?)(.+)\]\s*$/);
    if (k) { del = k[1] === '-'; key = fullKey(k[2]); if (del) settings.push({ key, name: '(key)', type: 'delkey', data: '' }); continue; }
    if (!key || del) continue;
    const m = l.match(/^(@|"((?:[^"\\]|\\.)*)")=(.*)$/); if (!m) continue;
    const name = m[1] === '@' ? '' : m[2].replace(/\\(.)/g, '$1'), v = m[3].trim();
    let type, data;
    if (v === '-') { type = 'del'; data = ''; }
    else if (/^dword:/i.test(v)) { type = 'dw'; data = String(parseInt(v.slice(6), 16)); }
    else if (/^hex\(b\):/i.test(v)) { type = 'qw'; const b = v.slice(7).split(',').map((x) => parseInt(x, 16)); data = String(b.reduceRight((a, x) => a * 256 + x, 0)); }
    else if (/^hex\(2\):/i.test(v)) { type = 'esz'; data = Buffer.from(v.slice(7).split(',').map((x) => parseInt(x, 16))).toString('utf16le').replace(/\0+$/, ''); }
    else if (/^hex\(7\):/i.test(v)) { type = 'msz'; data = Buffer.from(v.slice(7).split(',').map((x) => parseInt(x, 16))).toString('utf16le').replace(/\0+$/, '').split('\0').join('\x1E'); }
    else if (/^hex:/i.test(v)) { type = 'bin'; data = v.slice(4).toLowerCase(); }
    else if (/^"/.test(v)) { type = 'sz'; data = v.slice(1, -1).replace(/\\(.)/g, '$1'); }
    else continue;
    if (/%|!/.test(key + name)) continue;
    settings.push({ key, name, type, data });
  }
}

// ---------- walk the pack
function walk(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (SKIP.test(p)) continue;
    if (e.isDirectory()) { walk(p); continue; }
    const ext = path.extname(e.name).toLowerCase();
    if (ext === '.reg') regFile(readText(p));
    else if (ext === '.bat' || ext === '.cmd') {
      for (let l of readText(p).split(/\r?\n/)) {
        l = l.trim().replace(/\s*>\s*nul(\s*2>&1)?\s*$/i, '').replace(/\s*2>&1\s*$/, '');
        if (/^reg(\.exe)?\s+add\s/i.test(l)) regAdd(l);
        else if (/^(sc|schtasks|netsh|fsutil|wevtutil)(\.exe)?\s/i.test(l)) commands.push({ kind: 'cmd', text: l });
      }
    } else if (/disabled_services\.txt$/i.test(p)) {
      for (const s of readText(p).split(/\r?\n/).map((x) => x.trim()).filter(Boolean)) commands.push({ kind: 'cmd', text: 'sc config "' + s + '" start= disabled' });
    } else if (/disabled_tasks\.txt$/i.test(p)) {
      for (const s of readText(p).split(/\r?\n/).map((x) => x.trim()).filter(Boolean)) commands.push({ kind: 'cmd', text: 'schtasks /Change /TN "' + s + '" /Disable' });
    }
  }
}
walk(packDir);

// ---------- merge into the library
const lines = zlib.gunzipSync(fs.readFileSync(libFile)).toString('utf8').split(/\r?\n/).filter((l) => l.length);
const header = lines.shift();
const byKey = new Map(), cmdSet = new Set();
lines.forEach((l, i) => {
  const f = l.split('\t');
  if (f[0] === 'S') byKey.set((f[5] === '1' ? '*' : '') + f[6].toLowerCase() + '|' + f[7].toLowerCase(), i);
  else if (f[0] === 'C') cmdSet.add(f[6].replace(/\s+/g, ' ').trim().toLowerCase());
});
const src = 'JDO_PACKS\\' + packName;
let merged = 0, added = 0, newVals = 0, cmdsAdded = 0;
const seenNew = new Map();
for (const s of settings) {
  const id = s.key.toLowerCase() + '|' + s.name.toLowerCase();
  const v = s.type + '\x1F' + s.data;
  if (byKey.has(id)) {
    const i = byKey.get(id), f = lines[i].split('\t');
    if (seenNew.get(id) === 'counted') continue;   // one pack counts once per setting
    seenNew.set(id, 'counted');
    f[4] = String(Number(f[4]) + 1);
    let found = false;
    for (let k = 9; k < f.length; k++) {
      const p = f[k].split('\x1F');
      if (p[0] + '\x1F' + p[1] === v) { p[2] = String(Number(p[2] || 1) + 1); f[k] = p.join('\x1F'); found = true; }
    }
    if (!found) { f.push(v + '\x1F1'); newVals++; }
    // the app reads the first value as the most used one: keep them in that order
    const vals = f.slice(9).sort((a, b) => Number(b.split('\x1F')[2] || 1) - Number(a.split('\x1F')[2] || 1));
    lines[i] = f.slice(0, 9).concat(vals).join('\t'); merged++;
  } else {
    lines.push(['S', 'advanced', '1', '0', '1', '', s.key, s.name, src, v + '\x1F1'].join('\t'));
    byKey.set(id, lines.length - 1); seenNew.set(id, 'counted'); added++;
  }
}
for (const c of commands) {
  const n = c.text.replace(/\s+/g, ' ').trim().toLowerCase();
  if (cmdSet.has(n)) continue;
  cmdSet.add(n);
  lines.push(['C', 'advanced', '1', '0', '1', c.kind, c.text, src].join('\t'));
  cmdsAdded++;
}
fs.writeFileSync(libFile, zlib.gzipSync(Buffer.from([header, ...lines].join('\r\n') + '\r\n', 'utf8')));
console.log(`pack "${packName}": ${settings.length} registry values read, ${commands.length} commands read`);
console.log(`  already in the library: ${merged} (new values for them: ${newVals}); new settings: ${added}; new commands: ${cmdsAdded}`);
