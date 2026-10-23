// End-to-end test of app updates on a throw-away copy of the server (own port, database and folders):
// owner uploads an EXE -> /api/app/latest announces it -> the file downloads with the same SHA-256;
// an older or broken upload is refused; a normal user can't publish.
//   node test/e2e-updates.js
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'jdo-upd-'));
Object.assign(process.env, {
  NODE_ENV: 'development', PORT: '8099', BASE_URL: 'http://localhost:8099', MAIL_CONSOLE: '1',
  DATA_DIR: path.join(tmp, 'data'), RELEASES_DIR: path.join(tmp, 'releases'), DOWNLOAD_FILE: path.join(tmp, 'files', 'JdoTweak.exe'),
});
fs.mkdirSync(process.env.DATA_DIR, { recursive: true });

const app = require('../src/server');
const db = require('../src/db');
const sha = (b) => crypto.createHash('sha256').update(b).digest('hex');

let pass = 0, fail = 0;
const check = (what, ok) => { console.log((ok ? 'PASS  ' : 'FAIL  ') + what); ok ? pass++ : fail++; };

function session(email, role) {
  const u = db.prepare('INSERT INTO users (email, pass_hash, role, verified) VALUES (?, ?, ?, 1)').run(email, 'x', role);
  const token = crypto.randomBytes(24).toString('hex');
  db.prepare("INSERT INTO sessions (token, user_id, kind, expires_at) VALUES (?, ?, 'client', ?)").run(sha(token), u.lastInsertRowid, Date.now() + 3600e3);
  return token;
}
const exe = (n) => { const b = crypto.randomBytes(n); b[0] = 0x4d; b[1] = 0x5a; return b; };

(async () => {
  const server = app.listen(8099);
  const base = 'http://localhost:8099';
  const owner = session('owner@test.local', 'owner'), user = session('user@test.local', 'user');
  const up = (token, version, body) => fetch(`${base}/api/owner/release/upload?version=${version}&notes=test`, {
    method: 'POST', headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/octet-stream' }, body });
  try {
    const v1 = exe(300000);
    let r = await up(owner, '1.0.1', v1), j = await r.json();
    check('owner uploads 1.0.1', r.ok && j.ok && j.sha256 === sha(v1));

    j = await (await fetch(base + '/api/app/latest')).json();
    check('latest is 1.0.1 with the right checksum', j.version === '1.0.1' && j.sha256 === sha(v1) && j.url === base + '/api/app/file/1.0.1');

    const got = Buffer.from(await (await fetch(j.url)).arrayBuffer());
    check('the update downloads byte for byte', sha(got) === sha(v1));
    check('the website download is the new version', sha(fs.readFileSync(process.env.DOWNLOAD_FILE)) === sha(v1));

    r = await up(owner, '1.0.1', exe(300000)); j = await r.json();
    check('the same or an older version is refused', r.status === 400 && j.error === 'older');

    r = await up(owner, '1.0.2', Buffer.from('not an exe'.repeat(20000))); j = await r.json();
    check('a file that is not an EXE is refused', r.status === 400 && j.error === 'file');

    r = await up(user, '1.0.3', exe(300000));
    check('a normal user cannot publish', r.status === 403);

    r = await up('', '1.0.3', exe(300000));
    check('no sign-in cannot publish', r.status === 403);

    const v2 = exe(250000);
    r = await up(owner, '1.1.0', v2); j = await r.json();
    j = await (await fetch(base + '/api/app/latest')).json();
    check('next upload 1.1.0 becomes the latest', j.version === '1.1.0' && j.sha256 === sha(v2));
  } catch (e) { check('no exception: ' + e.message, false); }
  server.close();
  console.log(`\nPASS ${pass}  FAIL ${fail}`);
  process.exit(fail ? 1 : 0);
})();
