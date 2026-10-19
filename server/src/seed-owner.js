// Creates (or updates) the owner account. The password is read from the environment
// once and stored only as a bcrypt hash - never written to any file.
//   OWNER_EMAIL=... OWNER_PASSWORD=... npm run seed-owner
require('dotenv').config();
const bcrypt = require('bcryptjs');
const db = require('./db');

const email = String(process.env.OWNER_EMAIL || '').trim().toLowerCase();
const pass = process.env.OWNER_PASSWORD || '';
if (!email || pass.length < 8) { console.error('Set OWNER_EMAIL and OWNER_PASSWORD (8+ chars).'); process.exit(1); }

const hash = bcrypt.hashSync(pass, 12);
const u = db.prepare('SELECT id FROM users WHERE email = ?').get(email);
if (u) db.prepare("UPDATE users SET pass_hash = ?, role = 'owner', verified = 1, banned = 0 WHERE id = ?").run(hash, u.id);
else db.prepare("INSERT INTO users (email, pass_hash, role, verified) VALUES (?, ?, 'owner', 1)").run(email, hash);
console.log(`Owner account ready: ${email}`);
