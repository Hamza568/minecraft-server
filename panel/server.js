'use strict';

const express  = require('express');
const { WebSocketServer } = require('ws');
const { spawn } = require('child_process');
const fsp      = require('fs/promises');
const fs       = require('fs');
const path     = require('path');
const http     = require('http');
const crypto   = require('crypto');
const multer   = require('multer');

// ── Config ────────────────────────────────────────────────────────────────────
const DATA_DIR       = process.env.DATA_DIR       || '/data';
const SERVER_JAR     = '/server.jar';
// Railway injects PORT for its HTTP proxy; fall back to PANEL_PORT then 80
const PANEL_PORT     = parseInt(process.env.PORT || process.env.PANEL_PORT || '80', 10);
const PANEL_PASSWORD = process.env.PANEL_PASSWORD  || 'admin';
const MAX_MEMORY     = process.env.MAX_MEMORY      || '1G';
const MIN_MEMORY     = process.env.MIN_MEMORY      || '512M';
const JVM_OPTS       = process.env.JVM_OPTS        || '';
const EULA_ACCEPTED  = (process.env.EULA           || '').toLowerCase() === 'true';
const AUTO_START     = (process.env.AUTO_START     || 'true').toLowerCase() === 'true';

// One-time random token for WebSocket auth (avoids storing credentials in WS URL)
const WS_TOKEN = crypto.randomBytes(24).toString('hex');

// ── State ─────────────────────────────────────────────────────────────────────
let mcProcess    = null;
let serverStatus = 'offline'; // offline | starting | online | stopping

const consoleHistory = [];
const MAX_HISTORY    = 2000;
const wsClients      = new Set();

// ── Helpers ───────────────────────────────────────────────────────────────────
const stripAnsi = s => s.replace(/\x1B\[[0-9;]*[mGKHFJ]/g, '');

function broadcast(obj) {
  const msg = JSON.stringify(obj);
  for (const ws of wsClients) if (ws.readyState === 1) ws.send(msg);
}

function appendLog(line) {
  line = stripAnsi(String(line)).replace(/\r/g, '');
  if (!line.trim()) return;
  consoleHistory.push(line);
  if (consoleHistory.length > MAX_HISTORY) consoleHistory.shift();
  broadcast({ type: 'log', line });
}

function setStatus(s) {
  serverStatus = s;
  broadcast({ type: 'status', status: s });
}

// Prevent directory traversal — all paths must stay inside DATA_DIR
function safePath(rel) {
  const abs = path.resolve(DATA_DIR, rel != null ? String(rel) : '');
  if (!abs.startsWith(path.resolve(DATA_DIR) + path.sep) && abs !== path.resolve(DATA_DIR)) {
    throw new Error('Path traversal denied');
  }
  return abs;
}

// ── Minecraft process management ──────────────────────────────────────────────
async function startServer() {
  if (mcProcess) return { ok: false, error: 'Server is already running' };
  if (!EULA_ACCEPTED) return { ok: false, error: 'EULA not accepted — set EULA=true' };

  await fsp.mkdir(DATA_DIR, { recursive: true });
  await fsp.writeFile(path.join(DATA_DIR, 'eula.txt'), 'eula=true\n');

  const args = [
    `-Xmx${MAX_MEMORY}`,
    `-Xms${MIN_MEMORY}`,
    ...(JVM_OPTS ? JVM_OPTS.split(/\s+/).filter(Boolean) : []),
    '-jar', SERVER_JAR,
    'nogui',
  ];

  appendLog(`[panel] Starting: java ${args.join(' ')}`);
  setStatus('starting');

  mcProcess = spawn('java', args, {
    cwd: DATA_DIR,
    stdio: ['pipe', 'pipe', 'pipe'],
  });

  const onData = chunk => {
    for (const line of chunk.toString().split('\n')) {
      appendLog(line);
      if (/Done \(/.test(line) && /For help/.test(line)) setStatus('online');
    }
  };

  mcProcess.stdout.on('data', onData);
  mcProcess.stderr.on('data', onData);

  mcProcess.on('error', err => {
    appendLog(`[panel] Spawn error: ${err.message}`);
    mcProcess = null;
    setStatus('offline');
  });

  mcProcess.on('exit', (code, signal) => {
    appendLog(`[panel] Server stopped — code=${code ?? '–'} signal=${signal ?? '–'}`);
    mcProcess = null;
    setStatus('offline');
  });

  return { ok: true };
}

function stopServer(force = false) {
  if (!mcProcess) return { ok: false, error: 'Server is not running' };
  setStatus('stopping');
  if (force || !mcProcess.stdin.writable) {
    mcProcess.kill('SIGTERM');
  } else {
    mcProcess.stdin.write('stop\n');
  }
  return { ok: true };
}

function sendCommand(cmd) {
  if (!mcProcess || !mcProcess.stdin.writable) {
    return { ok: false, error: 'Server is not running' };
  }
  mcProcess.stdin.write(`${cmd}\n`);
  appendLog(`> ${cmd}`);
  return { ok: true };
}

// ── Express app ───────────────────────────────────────────────────────────────
const app    = express();
const server = http.createServer(app);

// Basic auth — every request must pass before reaching any route
app.use((req, res, next) => {
  const auth = req.headers.authorization || '';
  if (auth.startsWith('Basic ')) {
    const colon = Buffer.from(auth.slice(6), 'base64').toString().indexOf(':');
    const pass  = Buffer.from(auth.slice(6), 'base64').toString().slice(colon + 1);
    if (pass === PANEL_PASSWORD) {
      // Deliver the WS token so the client can open an authenticated WS connection
      res.setHeader('X-WS-Token', WS_TOKEN);
      return next();
    }
  }
  res.setHeader('WWW-Authenticate', 'Basic realm="MC Panel"');
  res.status(401).end('Unauthorized');
});

app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// Multer — disk storage; destination resolved via safePath
const upload = multer({
  storage: multer.diskStorage({
    destination(req, file, cb) {
      try {
        const dest = safePath(req.query.path || '');
        fs.mkdirSync(dest, { recursive: true });
        cb(null, dest);
      } catch (e) { cb(e); }
    },
    filename(req, file, cb) { cb(null, file.originalname); },
  }),
});

// ── REST: server control ──────────────────────────────────────────────────────
app.get('/api/status', (req, res) =>
  res.json({ status: serverStatus, pid: mcProcess?.pid ?? null, eula: EULA_ACCEPTED }));

app.post('/api/server/start', async (req, res) => res.json(await startServer()));

app.post('/api/server/stop', (req, res) => res.json(stopServer(req.body?.force)));

app.post('/api/server/restart', async (req, res) => {
  if (mcProcess) {
    stopServer();
    await new Promise((resolve, reject) => {
      const interval = setInterval(() => { if (!mcProcess) { clearInterval(interval); resolve(); } }, 300);
      setTimeout(() => {
        clearInterval(interval);
        if (mcProcess) { mcProcess.kill('SIGKILL'); }
        resolve();
      }, 30_000);
    });
    // Brief pause to let the OS clean up the process
    await new Promise(r => setTimeout(r, 500));
  }
  res.json(await startServer());
});

app.post('/api/server/command', (req, res) =>
  res.json(sendCommand(String(req.body?.command ?? '').trim())));

app.get('/api/console/history', (req, res) =>
  res.json({ lines: consoleHistory }));

// ── REST: file system ─────────────────────────────────────────────────────────
app.get('/api/files', async (req, res) => {
  try {
    const dir  = safePath(req.query.path);
    const ents = await fsp.readdir(dir, { withFileTypes: true });
    const items = await Promise.all(ents.map(async e => {
      const stat = await fsp.stat(path.join(dir, e.name)).catch(() => null);
      return {
        name:  e.name,
        type:  e.isDirectory() ? 'dir' : 'file',
        size:  stat?.size  ?? 0,
        mtime: stat?.mtimeMs ?? 0,
      };
    }));
    items.sort((a, b) => {
      if (a.type !== b.type) return a.type === 'dir' ? -1 : 1;
      return a.name.localeCompare(b.name);
    });
    res.json({ items, cwd: path.relative(DATA_DIR, dir) });
  } catch (e) { res.status(400).json({ error: e.message }); }
});

app.get('/api/files/content', async (req, res) => {
  try {
    const p    = safePath(req.query.path);
    const stat = await fsp.stat(p);
    if (stat.size > 2 * 1024 * 1024) return res.status(413).json({ error: 'File too large (> 2 MB)' });
    res.json({ content: await fsp.readFile(p, 'utf8') });
  } catch (e) { res.status(400).json({ error: e.message }); }
});

app.post('/api/files/save', async (req, res) => {
  try {
    await fsp.writeFile(safePath(req.body.path), req.body.content ?? '', 'utf8');
    res.json({ ok: true });
  } catch (e) { res.status(400).json({ error: e.message }); }
});

app.post('/api/files/mkdir', async (req, res) => {
  try {
    await fsp.mkdir(safePath(req.body.path), { recursive: true });
    res.json({ ok: true });
  } catch (e) { res.status(400).json({ error: e.message }); }
});

app.delete('/api/files', async (req, res) => {
  try {
    await fsp.rm(safePath(req.query.path), { recursive: true, force: true });
    res.json({ ok: true });
  } catch (e) { res.status(400).json({ error: e.message }); }
});

app.get('/api/files/download', (req, res) => {
  try {
    const p = safePath(req.query.path);
    res.download(p, path.basename(p));
  } catch (e) { res.status(400).json({ error: e.message }); }
});

app.post('/api/files/upload', upload.array('files'), (req, res) =>
  res.json({ ok: true, count: req.files?.length ?? 0 }));

// ── WebSocket ─────────────────────────────────────────────────────────────────
const wss = new WebSocketServer({ server });

wss.on('connection', (ws, req) => {
  const token = new URL(req.url, 'http://x').searchParams.get('token');
  if (token !== WS_TOKEN) { ws.close(4001, 'Unauthorized'); return; }

  wsClients.add(ws);
  ws.send(JSON.stringify({ type: 'init', status: serverStatus, lines: consoleHistory }));
  ws.on('close', () => wsClients.delete(ws));
});

// ── Graceful shutdown (SIGTERM from Docker/Railway) ───────────────────────────
process.on('SIGTERM', () => {
  appendLog('[panel] SIGTERM received — stopping Minecraft gracefully…');
  if (mcProcess) {
    stopServer();
    const kill = setTimeout(() => mcProcess?.kill('SIGKILL'), 15_000);
    mcProcess.on('exit', () => { clearTimeout(kill); process.exit(0); });
  } else {
    process.exit(0);
  }
});

// ── Start ─────────────────────────────────────────────────────────────────────
server.listen(PANEL_PORT, () => {
  const pwWarn = PANEL_PASSWORD === 'admin' ? '  ⚠ Change PANEL_PASSWORD!' : '';
  console.log(`[panel] Listening on :${PANEL_PORT}${pwWarn}`);
  console.log(`[panel] EULA=${EULA_ACCEPTED}  AUTO_START=${AUTO_START}`);

  if (AUTO_START && EULA_ACCEPTED) {
    setTimeout(() => {
      startServer().then(r => {
        if (!r.ok) console.error('[panel] Auto-start failed:', r.error);
      });
    }, 1000);
  } else if (!EULA_ACCEPTED) {
    console.log('[panel] Set EULA=true to allow the server to start.');
  }
});
