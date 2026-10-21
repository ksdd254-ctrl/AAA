// JDO Lite - serves tools/litewin/vmtest/live (written by vm-live.ps1) on http://localhost:8787
const http = require('http');
const fs = require('fs');
const path = require('path');
const dir = path.join(__dirname, 'live');
const types = { '.html': 'text/html; charset=utf-8', '.png': 'image/png' };
http.createServer((req, res) => {
  const name = decodeURIComponent(req.url.split('?')[0]).replace(/^\/+/, '') || 'index.html';
  const file = path.join(dir, path.basename(name));
  fs.readFile(file, (err, data) => {
    if (err) { res.writeHead(404); res.end('not yet'); return; }
    res.writeHead(200, { 'Content-Type': types[path.extname(file)] || 'application/octet-stream', 'Cache-Control': 'no-store' });
    res.end(data);
  });
}).listen(8787, '127.0.0.1', () => console.log('live view on http://localhost:8787'));
