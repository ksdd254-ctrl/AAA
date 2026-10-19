// SQLite storage. One file (data/jdo.db), created on first start.
const path = require('path');
const fs = require('fs');
const Database = require('better-sqlite3');

const dir = process.env.DATA_DIR || path.join(__dirname, '..', 'data');
fs.mkdirSync(dir, { recursive: true });
const db = new Database(path.join(dir, 'jdo.db'));
db.pragma('journal_mode = WAL');
db.pragma('foreign_keys = ON');

db.exec(`
CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY,
  email TEXT NOT NULL UNIQUE COLLATE NOCASE,
  pass_hash TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'user',          -- user | owner
  verified INTEGER NOT NULL DEFAULT 0,
  free_tier INTEGER NOT NULL DEFAULT 0,       -- >0: owner granted free access at this tier
  banned INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  last_login TEXT
);
CREATE TABLE IF NOT EXISTS email_codes (
  email TEXT NOT NULL COLLATE NOCASE,
  purpose TEXT NOT NULL,                      -- verify | reset
  code_hash TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (email, purpose)
);
CREATE TABLE IF NOT EXISTS licenses (
  id INTEGER PRIMARY KEY,
  key TEXT NOT NULL UNIQUE,
  user_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
  tier INTEGER NOT NULL,                      -- 1 basic, 2 elite, 3 ultimate
  lite INTEGER NOT NULL DEFAULT 0,            -- includes the lite Windows image
  status TEXT NOT NULL DEFAULT 'active',      -- active | locked
  expires_at TEXT,                            -- NULL = lifetime
  hwid TEXT,                                  -- bound on first activation
  order_id INTEGER,
  note TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS sessions (
  token TEXT PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind TEXT NOT NULL,                         -- web | client
  license_id INTEGER,
  hwid TEXT,
  expires_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS orders (
  id INTEGER PRIMARY KEY,
  user_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
  plan TEXT NOT NULL,
  amount INTEGER NOT NULL,                    -- cents
  stripe_session TEXT UNIQUE,
  status TEXT NOT NULL DEFAULT 'pending',     -- pending | paid
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS news (
  id INTEGER PRIMARY KEY,
  title_ar TEXT, title_en TEXT, body_ar TEXT, body_en TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS releases (
  id INTEGER PRIMARY KEY,
  version TEXT NOT NULL, url TEXT NOT NULL, sha256 TEXT NOT NULL, notes TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
`);

module.exports = db;
