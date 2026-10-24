// Builds the "Gaming Performance" power plan from the powercfg lines of a tweak script (TsukiOS_Full_Tweaks.cmd):
//   - Release\Gaming Performance Power Plan.cmd   (standalone, works on any Windows 10 / 11)
//   - JdoTweak\Data\tweaks.json -> power.ultimate  (the app's power plan tweak, same script)
// Only "powercfg -setacvalueindex / -setdcvalueindex" lines are taken; nothing else from the source runs.
//   node tools\make-powerplan.js "<source .cmd>"
const fs = require('fs');
const path = require('path');
const root = path.join(__dirname, '..');
const src = fs.readFileSync(process.argv[2], 'utf8');
const GUID = '4a444f58-5154-4741-4d45-000000000001';   // fixed, so applying twice never makes a second plan

const seen = new Map();
for (const line of src.split(/\r?\n/)) {
  const m = line.match(/^powercfg\s+-set(ac|dc)valueindex\s+[0-9a-f-]{36}\s+([0-9a-f-]{36})\s+([0-9a-f-]{36})\s+(\d+)\b/i);
  if (m) seen.set(m[1].toLowerCase() + ' ' + m[2].toLowerCase() + ' ' + m[3].toLowerCase(), m[4]);   // last value wins
}
const sets = [...seen].map(([k, v]) => { const [ac, sub, set] = k.split(' '); return `powercfg -set${ac}valueindex %G% ${sub} ${set} ${v} >nul 2>&1`; });

const body = [
  'set "G=' + GUID + '"',
  ':: start from Ultimate Performance, else High performance, else Balanced (whichever this Windows has)',
  'powercfg /list | find /i "%G%" >nul && goto apply',
  'powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 %G% >nul 2>&1',
  'powercfg /list | find /i "%G%" >nul || powercfg -duplicatescheme 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c %G% >nul 2>&1',
  'powercfg /list | find /i "%G%" >nul || powercfg -duplicatescheme 381b4222-f694-41f0-9685-ff5bb260df2e %G% >nul 2>&1',
  ':: trimmed Windows builds may have none of those: start from whatever plan is active',
  'powercfg /list | find /i "%G%" >nul && goto apply',
  'for /f "tokens=2 delims=:(" %%a in (\'powercfg /getactivescheme\') do for /f "tokens=1" %%b in ("%%a") do set "CUR=%%b"',
  'if defined CUR powercfg -duplicatescheme %CUR% %G% >nul 2>&1',
  ':apply',
  'powercfg -changename %G% "Gaming Performance" "Maximum performance for games: no core parking, no USB / PCIe / disk power saving" >nul 2>&1',
  ':: settings a PC does not have (laptop lid, hybrid CPU classes, ...) are skipped by Windows',
  ...sets,
  'powercfg -setactive %G%',
];

const standalone = [
  '@echo off',
  'chcp 65001 >nul',
  'title Gaming Performance Power Plan',
  // fltmc needs admin rights but no service ("net session" fails when tweaks turned the Server service off)
  'fltmc >nul 2>&1 || (echo Run this file as administrator: right-click ^> Run as administrator & pause & exit /b 1)',
  'setlocal',
  ...body,
  'echo.',
  'powercfg /getactivescheme | find /i "%G%" >nul && (echo [OK] Gaming Performance power plan is active.) || (echo [!] Could not activate the plan.)',
  'powercfg /getactivescheme',
  'echo.',
  'echo To go back: Control Panel ^> Power Options ^> Balanced.',
  'pause',
  '',
].join('\r\n');
fs.writeFileSync(path.join(root, 'Release', 'Gaming Performance Power Plan.cmd'), standalone, 'ascii');

// the app's tweak: same plan, undone by going back to Balanced and removing ours
const tf = path.join(root, 'JdoTweak', 'Data', 'tweaks.json');
const raw = fs.readFileSync(tf, 'utf8');
const j = JSON.parse(raw);
const t = j.tweaks.find((x) => x.id === 'power.ultimate');
t.ar = 'خطة طاقة الألعاب (Gaming Performance)';
t.en = 'Gaming Performance Power Plan';
t.dar = 'خطة طاقة كاملة للألعاب (' + seen.size + ' إعداد): المعالج على أقصى أداء وبدون ركن أنوية، وبدون توفير طاقة لـ USB و PCIe والهارد و NVMe. تشتغل على أي ويندوز وما تتكرر.';
t.den = 'A complete power plan for games (' + seen.size + ' settings): CPU at full performance with no core parking, no USB / PCIe / disk / NVMe power saving. Works on any Windows and never duplicates.';
t.apply = [{ script: '@echo off\r\nsetlocal\r\n' + body.join('\r\n') + '\r\n', ext: '.cmd' }];
// back to Balanced, or to any other plan this Windows has, then remove ours (the active plan can't be deleted)
t.revert = [{ script: [
  '@echo off', 'setlocal', 'set "G=' + GUID + '"',
  'powercfg -setactive 381b4222-f694-41f0-9685-ff5bb260df2e >nul 2>&1',
  'powercfg /getactivescheme | find /i "%G%" >nul && for /f "tokens=2 delims=:(" %%a in (\'powercfg /list ^| findstr /i "GUID" ^| findstr /v /i "%G%"\') do for /f "tokens=1" %%b in ("%%a") do powercfg -setactive %%b >nul 2>&1',
  'powercfg -delete %G% >nul 2>&1', '',
].join('\r\n'), ext: '.cmd' }];
const indent = raw.match(/\n( +)"/)[1].length;
fs.writeFileSync(tf, JSON.stringify(j, null, indent) + '\n');
console.log('power settings:', seen.size, 'lines:', sets.length);
