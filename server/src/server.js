// JDO Al-Shayeb Tweak - website + API
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const express = require('express');
const helmet = require('helmet');
const cookieParser = require('cookie-parser');
const rateLimit = require('express-rate-limit');
const bcrypt = require('bcryptjs');
const cfg = require('./config');
const db = require('./db');
const mail = require('./mail');
const stripe = cfg.stripeSecret ? require('stripe')(cfg.stripeSecret) : null;

// ---------------------------------------------------------------- helpers
const secretFile = path.join(process.env.DATA_DIR || path.join(__dirname, '..', 'data'), 'secret');
if (!fs.existsSync(secretFile)) fs.writeFileSync(secretFile, crypto.randomBytes(32).toString('hex'));
const SECRET = process.env.APP_SECRET || fs.readFileSync(secretFile, 'utf8').trim();

const now = () => Date.now();
const token = () => crypto.randomBytes(32).toString('base64url');
const sha = (s) => crypto.createHash('sha256').update(s).digest('hex');
const emailOk = (e) => typeof e === 'string' && /^[^\s@]{1,64}@[^\s@]{1,255}\.[^\s@]{2,}$/.test(e) && e.length <= 254;
const passOk = (p) => typeof p === 'string' && p.length >= 8 && p.length <= 128;
const clean = (s, n = 4000) => (typeof s === 'string' ? s : '').slice(0, n);

function newKey() {
  const abc = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  const b = crypto.randomBytes(16);
  let s = '';
  for (let i = 0; i < 16; i++) s += abc[b[i] % abc.length];
  return 'JDO-' + s.match(/.{4}/g).join('-');
}

function expired(lic) { return lic.expires_at && new Date(lic.expires_at + 'Z').getTime() < now(); }

function signDownload(licenseId, days = 7) {
  const exp = now() + days * 864e5;
  const sig = crypto.createHmac('sha256', SECRET).update(`${licenseId}.${exp}`).digest('base64url');
  return `${cfg.baseUrl}/dl/${licenseId}.${exp}.${sig}`;
}

async function sendCode(email, purpose) {
  const code = String(crypto.randomInt(100000, 1000000));
  db.prepare(`INSERT INTO email_codes (email, purpose, code_hash, expires_at, attempts) VALUES (?, ?, ?, ?, 0)
              ON CONFLICT(email, purpose) DO UPDATE SET code_hash = excluded.code_hash, expires_at = excluded.expires_at, attempts = 0`)
    .run(email, purpose, sha(code + SECRET), now() + 10 * 60e3);
  await mail.code(email, code);
}

function checkCode(email, purpose, code) {
  const row = db.prepare('SELECT * FROM email_codes WHERE email = ? AND purpose = ?').get(email, purpose);
  if (!row || row.expires_at < now() || row.attempts >= 5) return false;
  if (row.code_hash !== sha(String(code) + SECRET)) {
    db.prepare('UPDATE email_codes SET attempts = attempts + 1 WHERE email = ? AND purpose = ?').run(email, purpose);
    return false;
  }
  db.prepare('DELETE FROM email_codes WHERE email = ? AND purpose = ?').run(email, purpose);
  return true;
}

async function human(req) {
  if (!cfg.turnstileSecret) return cfg.dev;   // production must have Turnstile configured
  const r = await fetch('https://challenges.cloudflare.com/turnstile/v0/siteverify', {
    method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ secret: cfg.turnstileSecret, response: String(req.body.captcha || ''), remoteip: req.ip }),
  }).then((x) => x.json()).catch(() => ({}));
  return r.success === true;
}

function startSession(res, user) {
  const t = token();
  db.prepare("INSERT INTO sessions (token, user_id, kind, expires_at) VALUES (?, ?, 'web', ?)").run(sha(t), user.id, now() + 30 * 864e5);
  db.prepare("UPDATE users SET last_login = datetime('now') WHERE id = ?").run(user.id);
  res.cookie('sid', t, { httpOnly: true, sameSite: 'lax', secure: !cfg.dev, maxAge: 30 * 864e5 });
}

function webUser(req) {
  const t = req.cookies.sid;
  if (!t) return null;
  const s = db.prepare("SELECT * FROM sessions WHERE token = ? AND kind = 'web' AND expires_at > ?").get(sha(t), now());
  if (!s) return null;
  const u = db.prepare('SELECT * FROM users WHERE id = ?').get(s.user_id);
  return u && !u.banned ? u : null;
}

const auth = (req, res, next) => { const u = webUser(req); if (!u) return res.status(401).json({ ok: false, error: 'login' }); req.user = u; next(); };
const owner = (req, res, next) => { const u = webUser(req); if (!u || u.role !== 'owner') return res.status(403).json({ ok: false, error: 'forbidden' }); req.user = u; next(); };

function userView(u) {
  const lics = db.prepare('SELECT * FROM licenses WHERE user_id = ? ORDER BY id DESC').all(u.id);
  const canDownload = grantedPlan(u).tier > 0 || lics.some((l) => l.status === 'active' && !expired(l));
  return {
    email: u.email, role: u.role, freeTier: u.free_tier,
    licenses: lics.map((l) => ({ key: l.key, tier: l.tier, lite: !!l.lite, status: l.status, expires: l.expires_at, bound: !!l.hwid, expired: !!expired(l) })),
    download: canDownload ? '/api/download' : null,
    lite: cfg.liteWindowsUrl && lics.some((l) => l.lite && l.status === 'active' && !expired(l)) ? cfg.liteWindowsUrl : null,
  };
}

// ---------------------------------------------------------------- app
const app = express();
app.set('trust proxy', 1);

// Express 4 does not catch errors thrown inside async handlers; without this a single
// failure (e.g. the mail server rejecting a login) crashes the whole process.
for (const m of ['get', 'post']) {
  const orig = app[m].bind(app);
  app[m] = (p, ...hs) => orig(p, ...hs.map((h) => (typeof h === 'function' && h.length < 4
    ? (req, res, next) => { try { const r = h(req, res, next); if (r && typeof r.catch === 'function') r.catch(next); } catch (e) { next(e); } }
    : h)));
}
process.on('unhandledRejection', (e) => console.error('unhandled', e));
app.use(helmet({
  contentSecurityPolicy: {
    directives: {
      defaultSrc: ["'self'"],
      scriptSrc: ["'self'", 'https://challenges.cloudflare.com'],
      frameSrc: ['https://challenges.cloudflare.com'],
      styleSrc: ["'self'", "'unsafe-inline'", 'https://fonts.googleapis.com'],
      fontSrc: ["'self'", 'https://fonts.gstatic.com'],
      imgSrc: ["'self'", 'data:'],
      connectSrc: ["'self'"],
    },
  },
}));

// Stripe needs the raw body to verify the signature, so this route comes before express.json().
app.post('/api/stripe/webhook', express.raw({ type: 'application/json' }), async (req, res) => {
  if (!stripe) return res.sendStatus(404);
  let ev;
  try { ev = stripe.webhooks.constructEvent(req.body, req.headers['stripe-signature'], cfg.stripeWebhookSecret); }
  catch { return res.sendStatus(400); }
  if (ev.type === 'checkout.session.completed' && ev.data.object.payment_status === 'paid') {
    const order = db.prepare('SELECT * FROM orders WHERE stripe_session = ?').get(ev.data.object.id);
    if (order) await fulfill(order);
  }
  res.json({ received: true });
});

app.use(express.json({ limit: '64kb' }));
app.use(cookieParser());

// Only JSON POSTs reach the API: cross-site HTML forms can't send them, which blocks CSRF.
app.use('/api', (req, res, next) => {
  if (req.method === 'POST' && !req.is('application/json')) return res.status(415).json({ ok: false, error: 'json' });
  next();
});

const authLimit = rateLimit({ windowMs: 15 * 60e3, limit: 30, standardHeaders: true, legacyHeaders: false });
const codeLimit = rateLimit({ windowMs: 60 * 60e3, limit: 8, standardHeaders: true, legacyHeaders: false });

// ---------------------------------------------------------------- website accounts
app.get('/api/config', (req, res) => res.json({
  turnstile: cfg.turnstileSite || null,
  plans: Object.entries(cfg.plans).map(([id, p]) => ({ id, tier: p.tier, lite: p.lite, price: p.price / 100, ar: p.ar, en: p.en })),
}));

app.post('/api/auth/register', authLimit, codeLimit, async (req, res) => {
  const email = String(req.body.email || '').trim().toLowerCase();
  const pass = req.body.password;
  if (!emailOk(email) || !passOk(pass)) return res.status(400).json({ ok: false, error: 'invalid' });
  if (!(await human(req))) return res.status(400).json({ ok: false, error: 'captcha' });
  const u = db.prepare('SELECT * FROM users WHERE email = ?').get(email);
  if (u && u.verified) return res.status(409).json({ ok: false, error: 'exists' });
  const hash = await bcrypt.hash(pass, 12);
  if (u) db.prepare('UPDATE users SET pass_hash = ? WHERE id = ?').run(hash, u.id);
  else db.prepare('INSERT INTO users (email, pass_hash, role) VALUES (?, ?, ?)').run(email, hash, email === cfg.ownerEmail ? 'owner' : 'user');
  await sendCode(email, 'verify');
  res.json({ ok: true, next: 'verify' });
});

app.post('/api/auth/verify', authLimit, (req, res) => {
  const email = String(req.body.email || '').trim().toLowerCase();
  if (!checkCode(email, 'verify', req.body.code)) return res.status(400).json({ ok: false, error: 'code' });
  db.prepare('UPDATE users SET verified = 1 WHERE email = ?').run(email);
  const u = db.prepare('SELECT * FROM users WHERE email = ?').get(email);
  startSession(res, u);
  res.json({ ok: true, user: userView(u) });
});

app.post('/api/auth/login', authLimit, async (req, res) => {
  const email = String(req.body.email || '').trim().toLowerCase();
  if (!(await human(req))) return res.status(400).json({ ok: false, error: 'captcha' });
  const u = db.prepare('SELECT * FROM users WHERE email = ?').get(email);
  if (!u || !(await bcrypt.compare(String(req.body.password || ''), u.pass_hash))) return res.status(401).json({ ok: false, error: 'credentials' });
  if (u.banned) return res.status(403).json({ ok: false, error: 'banned' });
  if (!u.verified) { await sendCode(email, 'verify'); return res.json({ ok: true, next: 'verify' }); }
  startSession(res, u);
  res.json({ ok: true, user: userView(u) });
});

app.post('/api/auth/forgot', authLimit, codeLimit, async (req, res) => {
  const email = String(req.body.email || '').trim().toLowerCase();
  if (!(await human(req))) return res.status(400).json({ ok: false, error: 'captcha' });
  if (db.prepare('SELECT 1 FROM users WHERE email = ?').get(email)) await sendCode(email, 'reset');
  res.json({ ok: true });   // same answer either way, so emails can't be probed
});

app.post('/api/auth/reset', authLimit, async (req, res) => {
  const email = String(req.body.email || '').trim().toLowerCase();
  if (!passOk(req.body.password) || !checkCode(email, 'reset', req.body.code)) return res.status(400).json({ ok: false, error: 'code' });
  const u = db.prepare('SELECT * FROM users WHERE email = ?').get(email);
  db.prepare('UPDATE users SET pass_hash = ?, verified = 1 WHERE id = ?').run(await bcrypt.hash(req.body.password, 12), u.id);
  db.prepare('DELETE FROM sessions WHERE user_id = ?').run(u.id);
  startSession(res, u);
  res.json({ ok: true, user: userView(u) });
});

app.post('/api/auth/logout', (req, res) => {
  if (req.cookies.sid) db.prepare('DELETE FROM sessions WHERE token = ?').run(sha(req.cookies.sid));
  res.clearCookie('sid');
  res.json({ ok: true });
});

app.get('/api/me', auth, (req, res) => res.json({ ok: true, user: userView(req.user) }));

// ---------------------------------------------------------------- purchase
app.post('/api/checkout', auth, async (req, res) => {
  const plan = cfg.plans[req.body.plan];
  if (!plan) return res.status(400).json({ ok: false, error: 'plan' });
  const info = db.prepare('INSERT INTO orders (user_id, plan, amount) VALUES (?, ?, ?)').run(req.user.id, req.body.plan, plan.price);
  const orderId = info.lastInsertRowid;
  if (!stripe) {
    if (!cfg.dev || process.env.DEV_PAY !== '1') return res.status(503).json({ ok: false, error: 'payments' });
    return res.json({ ok: true, url: `/api/dev/pay/${orderId}` });   // dev only: simulate a paid order
  }
  const s = await stripe.checkout.sessions.create({
    mode: 'payment',
    customer_email: req.user.email,
    line_items: [{ quantity: 1, price_data: { currency: 'usd', unit_amount: plan.price, product_data: { name: `JDO Tweak - ${plan.en}` } } }],
    metadata: { order_id: String(orderId) },
    success_url: `${cfg.baseUrl}/account.html?paid=1`,
    cancel_url: `${cfg.baseUrl}/#plans`,
  });
  db.prepare('UPDATE orders SET stripe_session = ? WHERE id = ?').run(s.id, orderId);
  res.json({ ok: true, url: s.url });
});

// Simulated payments only when explicitly switched on for local tests (DEV_PAY=1).
// Never on by default: the server may be reachable from the internet while still in dev mode.
if (cfg.dev && !stripe && process.env.DEV_PAY === '1') {
  app.get('/api/dev/pay/:id', async (req, res) => {
    const order = db.prepare('SELECT * FROM orders WHERE id = ?').get(req.params.id);
    if (order) await fulfill(order);
    res.redirect('/account.html?paid=1');
  });
}

async function fulfill(order) {
  const done = db.prepare("UPDATE orders SET status = 'paid' WHERE id = ? AND status = 'pending'").run(order.id);
  if (!done.changes) return;   // already fulfilled (webhooks can repeat)
  const plan = cfg.plans[order.plan];
  const key = newKey();
  const lic = db.prepare('INSERT INTO licenses (key, user_id, tier, lite, order_id) VALUES (?, ?, ?, ?, ?)').run(key, order.user_id, plan.tier, plan.lite ? 1 : 0, order.id);
  const u = db.prepare('SELECT * FROM users WHERE id = ?').get(order.user_id);
  if (u) await mail.purchase(u.email, `${plan.ar} · ${plan.en}`, key, signDownload(lic.lastInsertRowid), plan.lite ? cfg.liteWindowsUrl : '');
}

// ---------------------------------------------------------------- downloads
function sendInstaller(res) {
  if (!fs.existsSync(cfg.downloadFile)) return res.status(503).send('Download not available yet');
  res.download(cfg.downloadFile, 'JdoTweak.exe');
}

app.get('/api/download', (req, res) => {
  const u = webUser(req);
  if (!u) return res.redirect('/account.html');
  if (!userView(u).download) return res.redirect('/#plans');
  sendInstaller(res);
});

app.get('/dl/:t', (req, res) => {
  const [id, exp, sig] = String(req.params.t).split('.');
  const want = crypto.createHmac('sha256', SECRET).update(`${id}.${exp}`).digest('base64url');
  const valid = sig && want.length === sig.length && crypto.timingSafeEqual(Buffer.from(want), Buffer.from(sig)) && Number(exp) > now();
  const lic = valid && db.prepare('SELECT * FROM licenses WHERE id = ?').get(id);
  if (!lic || lic.status !== 'active' || expired(lic)) return res.redirect('/account.html');
  sendInstaller(res);
});

// ---------------------------------------------------------------- desktop app
// The plan the admin gave this account by hand (0 = none). The owner always has everything.
function grantedPlan(u) {
  if (u.role === 'owner') return { tier: 3, lite: true, expires: null };
  if (!u.free_tier) return { tier: 0, lite: false, expires: null };
  if (u.plan_expires && new Date(u.plan_expires + 'Z').getTime() < now()) return { tier: 0, lite: false, expires: null, ended: true };
  return { tier: u.free_tier, lite: !!u.plan_lite, expires: u.plan_expires ? u.plan_expires + 'Z' : null };
}

function clientResult(u, lic, sess) {
  const g = grantedPlan(u);
  const keyTier = lic ? lic.tier : 0;
  const tier = Math.max(g.tier, keyTier);
  const lite = g.lite || !!(lic && lic.lite);
  const expires = keyTier >= g.tier && lic ? (lic.expires_at ? lic.expires_at + 'Z' : null) : g.expires;
  return {
    ok: true, token: sess, email: u.email, role: u.role, tier, lite,
    liteUrl: lite && cfg.liteWindowsUrl ? cfg.liteWindowsUrl : null, expires,
  };
}

// Everyone with a verified account can sign in; without a key or an admin-granted plan they get tier 0
// (the app opens with everything locked until the admin gives them a plan). A key, when given, must be valid.
function checkLicense(u, key, hwid) {
  if (u.banned) return { error: 'locked' };
  if (!key) return { lic: null };
  const lic = db.prepare('SELECT * FROM licenses WHERE key = ?').get(String(key).trim().toUpperCase());
  if (!lic) return { error: 'credentials' };
  if (lic.user_id && lic.user_id !== u.id) return { error: 'credentials' };
  if (lic.status !== 'active') return { error: 'locked' };
  if (expired(lic)) return { error: 'expired' };
  if (lic.hwid && lic.hwid !== hwid) return { error: 'hwid' };
  return { lic };
}

app.post('/api/client/login', authLimit, async (req, res) => {
  const email = String(req.body.email || '').trim().toLowerCase();
  const hwid = clean(req.body.hwid, 64);
  const u = db.prepare('SELECT * FROM users WHERE email = ?').get(email);
  if (!u || !u.verified || !hwid || !(await bcrypt.compare(String(req.body.password || ''), u.pass_hash))) return res.status(401).json({ ok: false, error: 'credentials' });
  const r = checkLicense(u, req.body.key, hwid);
  if (r.error) return res.status(403).json({ ok: false, error: r.error });
  if (r.lic && !r.lic.hwid) db.prepare('UPDATE licenses SET hwid = ?, user_id = ? WHERE id = ?').run(hwid, u.id, r.lic.id);
  const t = token();
  db.prepare("INSERT INTO sessions (token, user_id, kind, license_id, hwid, expires_at) VALUES (?, ?, 'client', ?, ?, ?)")
    .run(sha(t), u.id, r.lic ? r.lic.id : null, hwid, now() + 30 * 864e5);
  db.prepare("UPDATE users SET last_login = datetime('now') WHERE id = ?").run(u.id);
  res.json(clientResult(u, r.lic, t));
});

function clientSession(req) {
  const t = String(req.body.token || '');
  const s = t && db.prepare("SELECT * FROM sessions WHERE token = ? AND kind = 'client' AND expires_at > ?").get(sha(t), now());
  if (!s) return null;
  const u = db.prepare('SELECT * FROM users WHERE id = ?').get(s.user_id);
  return u ? { s, u, t } : null;
}

// Called on every launch: re-checks lock, expiry, device and plan with fresh data.
app.post('/api/client/verify', (req, res) => {
  const c = clientSession(req);
  if (!c) return res.status(401).json({ ok: false, error: 'credentials' });
  if (c.s.hwid !== clean(req.body.hwid, 64)) return res.status(403).json({ ok: false, error: 'hwid' });
  if (c.u.banned) return res.status(403).json({ ok: false, error: 'locked' });
  let lic = null;
  if (c.s.license_id) {
    lic = db.prepare('SELECT * FROM licenses WHERE id = ?').get(c.s.license_id);
    if (!lic || lic.status !== 'active') return res.status(403).json({ ok: false, error: 'locked' });
    if (expired(lic)) return res.status(403).json({ ok: false, error: 'expired' });
    if (lic.hwid && lic.hwid !== c.s.hwid) return res.status(403).json({ ok: false, error: 'hwid' });
  }
  res.json(clientResult(c.u, lic, c.t));
});

// ---------------- sign-up from inside the app (the emailed code is the bot check here)
app.post('/api/client/register', authLimit, codeLimit, async (req, res) => {
  const email = String(req.body.email || '').trim().toLowerCase();
  const pass = req.body.password;
  if (!emailOk(email)) return res.status(400).json({ ok: false, error: 'email' });
  if (!passOk(pass)) return res.status(400).json({ ok: false, error: 'password' });
  const u = db.prepare('SELECT * FROM users WHERE email = ?').get(email);
  if (u && u.verified) return res.status(409).json({ ok: false, error: 'exists' });
  const hash = await bcrypt.hash(pass, 12);
  if (u) db.prepare('UPDATE users SET pass_hash = ? WHERE id = ?').run(hash, u.id);
  else db.prepare('INSERT INTO users (email, pass_hash, role) VALUES (?, ?, ?)').run(email, hash, email === cfg.ownerEmail ? 'owner' : 'user');
  await sendCode(email, 'verify');
  res.json({ ok: true });
});

app.post('/api/client/confirm', authLimit, (req, res) => {
  const email = String(req.body.email || '').trim().toLowerCase();
  if (!checkCode(email, 'verify', req.body.code)) return res.status(400).json({ ok: false, error: 'code' });
  db.prepare('UPDATE users SET verified = 1 WHERE email = ?').run(email);
  res.json({ ok: true });
});

// Forgotten password from the app: code to the email, then a new password. Same answer whether
// the email exists or not, so accounts can't be probed.
app.post('/api/client/forgot', authLimit, codeLimit, async (req, res) => {
  const email = String(req.body.email || '').trim().toLowerCase();
  if (!emailOk(email)) return res.status(400).json({ ok: false, error: 'email' });
  if (db.prepare('SELECT 1 FROM users WHERE email = ?').get(email)) await sendCode(email, 'reset');
  res.json({ ok: true });
});

app.post('/api/client/reset', authLimit, async (req, res) => {
  const email = String(req.body.email || '').trim().toLowerCase();
  if (!passOk(req.body.password)) return res.status(400).json({ ok: false, error: 'password' });
  if (!checkCode(email, 'reset', req.body.code)) return res.status(400).json({ ok: false, error: 'code' });
  const u = db.prepare('SELECT id FROM users WHERE email = ?').get(email);
  if (!u) return res.status(400).json({ ok: false, error: 'code' });
  db.prepare('UPDATE users SET pass_hash = ?, verified = 1 WHERE id = ?').run(await bcrypt.hash(req.body.password, 12), u.id);
  db.prepare('DELETE FROM sessions WHERE user_id = ?').run(u.id);   // sign out everywhere
  res.json({ ok: true });
});

app.post('/api/client/resend', authLimit, codeLimit, async (req, res) => {
  const email = String(req.body.email || '').trim().toLowerCase();
  const u = db.prepare('SELECT verified FROM users WHERE email = ?').get(email);
  if (u && !u.verified) await sendCode(email, 'verify');
  res.json({ ok: true });
});

app.post('/api/news', (req, res) => {
  const ar = req.body.lang !== 'en';
  const items = db.prepare('SELECT * FROM news ORDER BY id DESC LIMIT 5').all()
    .map((n) => ({ id: n.id, title: (ar ? n.title_ar : n.title_en) || n.title_en || n.title_ar, body: (ar ? n.body_ar : n.body_en) || n.body_en || n.body_ar, date: n.created_at }));
  res.json({ ok: true, items });
});

app.get('/api/app/latest', (req, res) => {
  const r = db.prepare('SELECT version, url, sha256, notes FROM releases ORDER BY id DESC LIMIT 1').get();
  res.json(r || { version: '0.0.0' });
});

// Owner actions from inside the desktop app.
function clientOwner(req, res, next) {
  const c = clientSession(req);
  if (!c || c.u.role !== 'owner') return res.status(403).json({ ok: false, error: 'forbidden' });
  req.user = c.u; next();
}
const postNews = (b) => db.prepare('INSERT INTO news (title_ar, title_en, body_ar, body_en) VALUES (?, ?, ?, ?)')
  .run(clean(b.titleAr, 200), clean(b.titleEn, 200), clean(b.bodyAr), clean(b.bodyEn));
const postRelease = (b) => {
  if (!/^\d+\.\d+\.\d+$/.test(b.version || '') || !/^https:\/\//.test(b.url || '') || !/^[0-9a-f]{64}$/.test(b.sha256 || '')) return false;
  db.prepare('INSERT INTO releases (version, url, sha256, notes) VALUES (?, ?, ?, ?)').run(b.version, b.url, b.sha256, clean(b.notes));
  return true;
};
app.post('/api/owner/news', clientOwner, (req, res) => { postNews(req.body); res.json({ ok: true }); });
app.post('/api/owner/release', clientOwner, (req, res) => res.json({ ok: postRelease(req.body) }));

// Admin from inside the app: list accounts and give / change / remove their plan.
app.post('/api/owner/users', clientOwner, (req, res) => {
  const q = '%' + clean(req.body.q, 100) + '%';
  const rows = db.prepare(`SELECT id, email, role, verified, free_tier, plan_lite, plan_expires, banned, created_at, last_login
    FROM users WHERE email LIKE ? ORDER BY id DESC LIMIT 300`).all(q);
  res.json({ ok: true, users: rows.map((u) => { const g = grantedPlan(u); return { id: u.id, email: u.email, role: u.role, verified: !!u.verified, banned: !!u.banned, tier: g.tier, lite: g.lite, expires: g.expires, ended: !!g.ended, created: u.created_at, lastLogin: u.last_login }; }) });
});

app.post('/api/owner/plan', clientOwner, (req, res) => {
  const u = db.prepare('SELECT * FROM users WHERE id = ?').get(Number(req.body.userId));
  if (!u) return res.status(404).json({ ok: false, error: 'user' });
  if (u.role === 'owner') return res.status(400).json({ ok: false, error: 'owner' });
  const tier = Number(req.body.tier);
  if (![0, 1, 2, 3].includes(tier)) return res.status(400).json({ ok: false, error: 'tier' });
  const days = Number(req.body.days) || 0;
  const exp = tier > 0 && days > 0 ? new Date(now() + days * 864e5).toISOString().slice(0, 19).replace('T', ' ') : null;
  db.prepare('UPDATE users SET free_tier = ?, plan_lite = ?, plan_expires = ? WHERE id = ?').run(tier, tier === 3 && req.body.lite ? 1 : 0, exp, u.id);
  res.json({ ok: true });
});

// ---------------------------------------------------------------- website admin (owner only)
app.get('/api/admin/stats', owner, (req, res) => res.json({
  ok: true,
  users: db.prepare('SELECT COUNT(*) n FROM users').get().n,
  licenses: db.prepare("SELECT COUNT(*) n FROM licenses WHERE status = 'active'").get().n,
  revenue: (db.prepare("SELECT COALESCE(SUM(amount),0) s FROM orders WHERE status = 'paid'").get().s) / 100,
  orders: db.prepare("SELECT COUNT(*) n FROM orders WHERE status = 'paid'").get().n,
}));

app.get('/api/admin/users', owner, (req, res) => {
  const q = '%' + String(req.query.q || '') + '%';
  const users = db.prepare(`SELECT u.id, u.email, u.role, u.verified, u.free_tier, u.banned, u.created_at, u.last_login,
      (SELECT COUNT(*) FROM licenses l WHERE l.user_id = u.id) AS keys
    FROM users u WHERE u.email LIKE ? ORDER BY u.id DESC LIMIT 200`).all(q);
  res.json({ ok: true, users });
});

app.post('/api/admin/users/:id', owner, (req, res) => {
  const u = db.prepare('SELECT * FROM users WHERE id = ?').get(req.params.id);
  if (!u) return res.status(404).json({ ok: false });
  if (u.id === req.user.id && (req.body.role === 'user' || req.body.banned)) return res.status(400).json({ ok: false, error: 'self' });
  const role = ['user', 'owner'].includes(req.body.role) ? req.body.role : u.role;
  const free = Number.isInteger(req.body.free_tier) && req.body.free_tier >= 0 && req.body.free_tier <= 3 ? req.body.free_tier : u.free_tier;
  const banned = typeof req.body.banned === 'boolean' ? (req.body.banned ? 1 : 0) : u.banned;
  db.prepare('UPDATE users SET role = ?, free_tier = ?, banned = ? WHERE id = ?').run(role, free, banned, u.id);
  if (banned) db.prepare('DELETE FROM sessions WHERE user_id = ?').run(u.id);
  res.json({ ok: true });
});

app.get('/api/admin/licenses', owner, (req, res) => {
  const q = '%' + String(req.query.q || '') + '%';
  const rows = db.prepare(`SELECT l.*, u.email FROM licenses l LEFT JOIN users u ON u.id = l.user_id
    WHERE l.key LIKE ? OR u.email LIKE ? ORDER BY l.id DESC LIMIT 300`).all(q, q);
  res.json({ ok: true, licenses: rows.map((l) => ({ ...l, expired: !!expired(l) })) });
});

app.post('/api/admin/licenses', owner, (req, res) => {
  const tier = Number(req.body.tier);
  if (![1, 2, 3].includes(tier)) return res.status(400).json({ ok: false });
  let userId = null;
  if (req.body.email) {
    const u = db.prepare('SELECT id FROM users WHERE email = ?').get(String(req.body.email).trim().toLowerCase());
    if (!u) return res.status(404).json({ ok: false, error: 'user' });
    userId = u.id;
  }
  const days = Number(req.body.days) || 0;
  const exp = days > 0 ? new Date(now() + days * 864e5).toISOString().slice(0, 19).replace('T', ' ') : null;
  const key = newKey();
  db.prepare('INSERT INTO licenses (key, user_id, tier, lite, expires_at, note) VALUES (?, ?, ?, ?, ?, ?)')
    .run(key, userId, tier, req.body.lite ? 1 : 0, exp, clean(req.body.note, 200));
  res.json({ ok: true, key });
});

app.post('/api/admin/licenses/:id', owner, (req, res) => {
  const l = db.prepare('SELECT * FROM licenses WHERE id = ?').get(req.params.id);
  if (!l) return res.status(404).json({ ok: false });
  const b = req.body;
  if (b.action === 'lock' || b.action === 'unlock') db.prepare('UPDATE licenses SET status = ? WHERE id = ?').run(b.action === 'lock' ? 'locked' : 'active', l.id);
  if (b.action === 'reset_hwid') {
    db.prepare('UPDATE licenses SET hwid = NULL WHERE id = ?').run(l.id);
    db.prepare("DELETE FROM sessions WHERE license_id = ? AND kind = 'client'").run(l.id);
  }
  if (b.action === 'extend') {
    const days = Number(b.days) || 0;
    const base = l.expires_at && !expired(l) ? new Date(l.expires_at + 'Z').getTime() : now();
    const exp = days > 0 ? new Date(base + days * 864e5).toISOString().slice(0, 19).replace('T', ' ') : null;   // 0 = lifetime
    db.prepare('UPDATE licenses SET expires_at = ? WHERE id = ?').run(exp, l.id);
  }
  if (b.action === 'tier' && [1, 2, 3].includes(Number(b.tier))) db.prepare('UPDATE licenses SET tier = ? WHERE id = ?').run(Number(b.tier), l.id);
  if (b.action === 'delete') db.prepare('DELETE FROM licenses WHERE id = ?').run(l.id);
  res.json({ ok: true });
});

app.get('/api/admin/news', owner, (req, res) => res.json({ ok: true, news: db.prepare('SELECT * FROM news ORDER BY id DESC LIMIT 50').all() }));
app.post('/api/admin/news', owner, (req, res) => { postNews(req.body); res.json({ ok: true }); });
app.post('/api/admin/news/:id/delete', owner, (req, res) => { db.prepare('DELETE FROM news WHERE id = ?').run(req.params.id); res.json({ ok: true }); });
app.post('/api/admin/release', owner, (req, res) => res.json({ ok: postRelease(req.body) }));

// ---------------------------------------------------------------- static site
app.use(express.static(path.join(__dirname, '..', 'public'), { extensions: ['html'] }));
app.use((err, req, res, next) => {
  if (err && err.mailFailed) return res.status(502).json({ ok: false, error: 'mail' });
  console.error(err);
  res.status(500).json({ ok: false, error: 'server' });
});

// ---------------------------------------------------------------- daily backup of the database
const backupDir = path.join(process.env.DATA_DIR || path.join(__dirname, '..', 'data'), 'backups');
async function backupNow() {
  fs.mkdirSync(backupDir, { recursive: true });
  const file = path.join(backupDir, `jdo-${new Date().toISOString().slice(0, 10)}.db`);
  await db.backup(file);
  // keep the last 14 days
  fs.readdirSync(backupDir).filter((f) => f.endsWith('.db')).sort().slice(0, -14)
    .forEach((f) => fs.unlinkSync(path.join(backupDir, f)));
  return file;
}

// Production must not start half-configured: no payments, no emails or no bot check would
// either lose sales or let anyone in.
function productionProblems() {
  const p = [];
  if (!/^https:\/\//.test(cfg.baseUrl)) p.push('BASE_URL must be your https:// domain');
  if (!stripe || !cfg.stripeWebhookSecret) p.push('STRIPE_SECRET_KEY and STRIPE_WEBHOOK_SECRET are required');
  if (!cfg.smtp) p.push('SMTP_HOST / SMTP_USER / SMTP_PASS are required to send codes and keys');
  if (!cfg.turnstileSecret || !cfg.turnstileSite) p.push('TURNSTILE_SITE_KEY and TURNSTILE_SECRET_KEY are required');
  if (!cfg.ownerEmail) p.push('OWNER_EMAIL is required');
  if (!fs.existsSync(cfg.downloadFile)) p.push(`the installer is missing: ${cfg.downloadFile}`);
  return p;
}

if (require.main === module) {
  if (!cfg.dev) {
    const p = productionProblems();
    if (p.length) { console.error('Cannot start in production:\n - ' + p.join('\n - ')); process.exit(1); }
  }
  app.listen(cfg.port, () => console.log(`JDO server on ${cfg.baseUrl} (${cfg.dev ? 'dev' : 'production'})`));
  backupNow().then((f) => console.log('backup: ' + f)).catch((e) => console.error('backup failed', e));
  setInterval(() => backupNow().catch((e) => console.error('backup failed', e)), 24 * 3600e3);
}
app.backupNow = backupNow;
app.productionProblems = productionProblems;
module.exports = app;
