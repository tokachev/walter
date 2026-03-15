#!/usr/bin/env node
// ======================================================================
//  Walter Dashboard — Multi-session real-time monitoring server
//
//  Runs on the HOST (not inside Docker containers).
//  Watches ~/.walter/sessions/*/ for audit, progress, and cost data
//  from all active and historical Walter sessions.
//
//  Usage:
//    node server.js --sessions-dir ~/.walter/sessions --port 19433
//
//  Endpoints:
//    GET /             — serves ui.html
//    GET /events       — SSE stream (session, audit, progress, cost)
//    GET /api/sessions — list all sessions with metadata
//    GET /api/plan     — parsed plan for a session (?session=<id>)
//    GET /api/status   — cost + audit + progress (?session=<id>)
// ======================================================================

'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');

// -- CLI args -------------------------------------------------------------

const argv = process.argv.slice(2);
let sessionsDir = path.join(os.homedir(), '.walter', 'sessions');
let port = 19433;

for (let i = 0; i < argv.length; i++) {
  if (argv[i] === '--sessions-dir' && argv[i + 1]) sessionsDir = argv[++i];
  else if (argv[i] === '--port' && argv[i + 1]) port = parseInt(argv[++i], 10);
}

// -- Read UI at startup ---------------------------------------------------

const uiPath = path.join(__dirname, 'ui.html');
let uiHtml;
try {
  uiHtml = fs.readFileSync(uiPath, 'utf-8');
} catch (err) {
  console.error(`Failed to read ui.html: ${err.message}`);
  process.exit(1);
}

// -- File Tailer ----------------------------------------------------------

class Tailer {
  constructor(filePath) {
    this.filePath = filePath;
    this.pos = 0;
    try { this.pos = fs.statSync(filePath).size; } catch {}
  }

  readNewLines() {
    try {
      const fd = fs.openSync(this.filePath, 'r');
      const stat = fs.fstatSync(fd);
      if (stat.size < this.pos) this.pos = 0;
      if (stat.size === this.pos) { fs.closeSync(fd); return []; }
      const buf = Buffer.alloc(stat.size - this.pos);
      fs.readSync(fd, buf, 0, buf.length, this.pos);
      fs.closeSync(fd);
      this.pos = stat.size;
      return buf.toString('utf-8').split('\n').filter(Boolean);
    } catch { return []; }
  }

  syncToEnd() {
    try { this.pos = fs.statSync(this.filePath).size; } catch {}
  }

  static readAllLines(filePath) {
    try { return fs.readFileSync(filePath, 'utf-8').split('\n').filter(Boolean); }
    catch { return []; }
  }
}

// -- Session --------------------------------------------------------------

class Session {
  constructor(dir) {
    this.dir = dir;
    this.id = path.basename(dir);
    this.auditPath = path.join(dir, 'audit.jsonl');
    this.progressPath = path.join(dir, 'progress.jsonl');
    this.costPath = path.join(dir, 'cost.json');
    this.auditTailer = new Tailer(this.auditPath);
    this.progressTailer = new Tailer(this.progressPath);
  }

  readMetadata() {
    try {
      return JSON.parse(fs.readFileSync(path.join(this.dir, 'session.json'), 'utf-8'));
    } catch {
      return { id: this.id, project_name: this.id };
    }
  }

  readCost() {
    try { return JSON.parse(fs.readFileSync(this.costPath, 'utf-8')); }
    catch { return null; }
  }

  getStatus() {
    // Check for done marker first (written by walter launcher on exit)
    try {
      const done = JSON.parse(fs.readFileSync(path.join(this.dir, 'done'), 'utf-8'));
      return done.status || 'completed';
    } catch {}
    // Infer from progress events
    try {
      const content = fs.readFileSync(this.progressPath, 'utf-8');
      if (content.includes('"plan_complete"')) return 'completed';
      // Check if last event is task_failed with no subsequent task_start
      const lines = content.trim().split('\n').filter(Boolean);
      if (lines.length > 0) {
        const last = JSON.parse(lines[lines.length - 1]);
        if (last.event === 'task_failed') return 'failed';
      }
    } catch {}
    // Check if any files exist (session started)
    try {
      if (fs.existsSync(this.auditPath) || fs.existsSync(this.progressPath)) return 'running';
    } catch {}
    return 'waiting';
  }

  getSummary() {
    const meta = this.readMetadata();
    const cost = this.readCost();
    return {
      id: this.id,
      project_name: meta.project_name || this.id,
      project_dir: meta.project_dir || '',
      plan_file: meta.plan_file || '',
      mode: meta.mode || 'interactive',
      cost_budget: meta.cost_budget || 5,
      started_at: meta.started_at || '',
      status: this.getStatus(),
      cost: cost ? (cost.total_cost_usd || 0) : 0,
      calls: cost ? (cost.calls || 0) : 0,
    };
  }

  getHostPlanPath() {
    const meta = this.readMetadata();
    if (!meta.plan_file || !meta.project_dir) return null;
    return path.join(meta.project_dir, meta.plan_file);
  }
}

// -- Session Manager ------------------------------------------------------

const sessions = new Map();

function scanSessions() {
  try {
    if (!fs.existsSync(sessionsDir)) return [];
    const newSessions = [];
    const dirs = fs.readdirSync(sessionsDir);
    for (const name of dirs) {
      const full = path.join(sessionsDir, name);
      try {
        if (!fs.statSync(full).isDirectory()) continue;
      } catch { continue; }
      if (!sessions.has(name)) {
        const session = new Session(full);
        sessions.set(name, session);
        newSessions.push(session);
      }
    }
    return newSessions;
  } catch { return []; }
}

// -- Plan parser ----------------------------------------------------------

function parsePlan(filePath) {
  try {
    const content = fs.readFileSync(filePath, 'utf-8');
    const tasks = [];
    const lines = content.split('\n');
    let currentTask = null;

    for (const line of lines) {
      const taskMatch = line.match(/^###\s+Task\s+(\d+):\s*(.*)/);
      if (taskMatch) {
        if (currentTask) tasks.push(currentTask);
        currentTask = { num: parseInt(taskMatch[1]), title: taskMatch[2].trim(), items: [] };
        continue;
      }
      if (currentTask) {
        const checkedMatch = line.match(/^\s*-\s\[([xX])\]\s*(.*)/);
        const uncheckedMatch = line.match(/^\s*-\s\[\s\]\s*(.*)/);
        const waitMatch = line.match(/^\s*-\s\[WAIT\]\s*(.*)/);
        if (checkedMatch) currentTask.items.push({ text: checkedMatch[2], checked: true });
        else if (uncheckedMatch) currentTask.items.push({ text: uncheckedMatch[1], checked: false });
        else if (waitMatch) currentTask.items.push({ text: waitMatch[1], checked: false, wait: true });
      }
    }
    if (currentTask) tasks.push(currentTask);
    return { tasks };
  } catch { return { tasks: [] }; }
}

// -- SSE ------------------------------------------------------------------

const clients = new Set();

function sendSSE(res, type, data) {
  try { res.write(`event: ${type}\ndata: ${JSON.stringify(data)}\n\n`); }
  catch {}
}

function broadcast(type, data) {
  for (const client of clients) sendSSE(client, type, data);
}

// Poll: read new lines from all sessions
function pollEvents() {
  if (clients.size === 0) return;
  for (const [id, session] of sessions) {
    for (const line of session.auditTailer.readNewLines()) {
      try { const d = JSON.parse(line); d._session = id; broadcast('audit', d); } catch {}
    }
    for (const line of session.progressTailer.readNewLines()) {
      try { const d = JSON.parse(line); d._session = id; broadcast('progress', d); } catch {}
    }
  }
}

// Poll: broadcast cost for all sessions
function pollCost() {
  if (clients.size === 0) return;
  for (const [id, session] of sessions) {
    const cost = session.readCost();
    if (cost) {
      cost._session = id;
      cost.budget_usd = session.readMetadata().cost_budget || 5;
      broadcast('cost', cost);
    }
  }
}

// Poll: scan for new sessions
function pollSessions() {
  const newSessions = scanSessions();
  if (newSessions.length === 0 || clients.size === 0) return;
  for (const session of newSessions) {
    broadcast('session', session.getSummary());
  }
}

// -- Replay on connect ----------------------------------------------------

function replayToClient(res) {
  scanSessions();

  // Send all session summaries
  for (const [id, session] of sessions) {
    sendSSE(res, 'session', session.getSummary());
  }

  // Replay events per session
  for (const [id, session] of sessions) {
    for (const line of Tailer.readAllLines(session.auditPath)) {
      try { const d = JSON.parse(line); d._session = id; sendSSE(res, 'audit', d); } catch {}
    }
    for (const line of Tailer.readAllLines(session.progressPath)) {
      try { const d = JSON.parse(line); d._session = id; sendSSE(res, 'progress', d); } catch {}
    }
    const cost = session.readCost();
    if (cost) {
      cost._session = id;
      cost.budget_usd = session.readMetadata().cost_budget || 5;
      sendSSE(res, 'cost', cost);
    }
    // Sync tailers after replay
    session.auditTailer.syncToEnd();
    session.progressTailer.syncToEnd();
  }
}

// -- HTTP Server ----------------------------------------------------------

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://localhost:${port}`);
  res.setHeader('Access-Control-Allow-Origin', '*');

  // SSE endpoint
  if (url.pathname === '/events' && req.method === 'GET') {
    res.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive',
    });
    replayToClient(res);
    clients.add(res);
    req.on('close', () => clients.delete(res));
    return;
  }

  // Sessions list API
  if (url.pathname === '/api/sessions' && req.method === 'GET') {
    scanSessions();
    const list = [];
    for (const [, session] of sessions) list.push(session.getSummary());
    // Sort: running first, then by start time desc
    list.sort((a, b) => {
      const statusOrder = { running: 0, waiting: 1, failed: 2, completed: 3 };
      const sa = statusOrder[a.status] ?? 4;
      const sb = statusOrder[b.status] ?? 4;
      if (sa !== sb) return sa - sb;
      return (b.started_at || '').localeCompare(a.started_at || '');
    });
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(list));
    return;
  }

  // Plan API
  if (url.pathname === '/api/plan' && req.method === 'GET') {
    const sessionId = url.searchParams.get('session');
    if (!sessionId || !sessions.has(sessionId)) {
      res.writeHead(404, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Session not found' }));
      return;
    }
    const session = sessions.get(sessionId);
    const planPath = session.getHostPlanPath();
    if (!planPath) {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ tasks: [] }));
      return;
    }
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(parsePlan(planPath)));
    return;
  }

  // Status API
  if (url.pathname === '/api/status' && req.method === 'GET') {
    const sessionId = url.searchParams.get('session');
    if (sessionId && sessions.has(sessionId)) {
      const session = sessions.get(sessionId);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(session.getSummary()));
    } else {
      scanSessions();
      const list = [];
      for (const [, s] of sessions) list.push(s.getSummary());
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(list));
    }
    return;
  }

  // Serve UI
  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Content-Length': Buffer.byteLength(uiHtml) });
  res.end(uiHtml);
});

// -- Poll intervals -------------------------------------------------------

const eventPoll = setInterval(pollEvents, 200);
const costPoll = setInterval(pollCost, 5000);
const sessionPoll = setInterval(pollSessions, 2000);

// -- Graceful shutdown ----------------------------------------------------

function shutdown() {
  clearInterval(eventPoll);
  clearInterval(costPoll);
  clearInterval(sessionPoll);
  for (const c of clients) { try { c.end(); } catch {} }
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 2000);
}

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

// -- Start ----------------------------------------------------------------

scanSessions();
const count = sessions.size;

server.listen(port, '0.0.0.0', () => {
  console.error(`Walter Dashboard — http://localhost:${port}`);
  console.error(`Sessions dir: ${sessionsDir}`);
  console.error(`Active sessions: ${count}`);
});
