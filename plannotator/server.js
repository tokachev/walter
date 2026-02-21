#!/usr/bin/env node
// ======================================================================
//  Plannotator Server — Node.js HTTP server for plan review UI
//
//  Usage:
//    node server.js --plan-file <path> --permission-mode <mode>
//
//  Serves the plan review UI and blocks until the user approves or
//  denies the plan. Outputs Claude Code hook JSON to stdout on decision.
//
//  All debug/info messages go to stderr. Only hook JSON goes to stdout.
// ======================================================================

'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');

// -- Parse CLI args -------------------------------------------------------

const args = process.argv.slice(2);
let planFile = null;
let permissionMode = 'default';

for (let i = 0; i < args.length; i++) {
  if (args[i] === '--plan-file' && args[i + 1]) {
    planFile = args[++i];
  } else if (args[i] === '--permission-mode' && args[i + 1]) {
    permissionMode = args[++i];
  }
}

if (!planFile) {
  process.stderr.write('Error: --plan-file is required\n');
  process.exit(1);
}

// -- Read plan content ----------------------------------------------------

let planContent;
try {
  planContent = fs.readFileSync(planFile, 'utf-8');
} catch (err) {
  process.stderr.write(`Error reading plan file: ${err.message}\n`);
  process.exit(1);
}

if (!planContent.trim()) {
  process.stderr.write('Error: plan file is empty\n');
  process.exit(1);
}

// -- Read UI HTML ---------------------------------------------------------

const uiPath = path.join(__dirname, 'ui.html');
let uiHtml;
try {
  uiHtml = fs.readFileSync(uiPath, 'utf-8');
} catch (err) {
  process.stderr.write(`Error reading ui.html: ${err.message}\n`);
  process.exit(1);
}

// -- Decision promise -----------------------------------------------------

let resolveDecision;
const decisionPromise = new Promise((resolve) => {
  resolveDecision = resolve;
});

// -- HTTP Server ----------------------------------------------------------

const PORT = parseInt(process.env.PLANNOTATOR_PORT || '19432', 10);
const MAX_RETRIES = 5;
const RETRY_DELAY_MS = 500;

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString()));
      } catch {
        resolve({});
      }
    });
    req.on('error', reject);
  });
}

function sendJson(res, statusCode, data) {
  const body = JSON.stringify(data);
  res.writeHead(statusCode, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(body),
  });
  res.end(body);
}

function sendHtml(res) {
  res.writeHead(200, {
    'Content-Type': 'text/html; charset=utf-8',
    'Content-Length': Buffer.byteLength(uiHtml),
  });
  res.end(uiHtml);
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);

  // CORS headers for local development
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  // API: Get plan content
  if (url.pathname === '/api/plan' && req.method === 'GET') {
    sendJson(res, 200, {
      plan: planContent,
      origin: 'claude-code',
      permissionMode: permissionMode,
    });
    return;
  }

  // API: Approve plan
  if (url.pathname === '/api/approve' && req.method === 'POST') {
    const body = await readBody(req);
    const effectiveMode = body.permissionMode || permissionMode;
    sendJson(res, 200, { ok: true });
    resolveDecision({
      approved: true,
      permissionMode: effectiveMode,
    });
    return;
  }

  // API: Deny with feedback
  if (url.pathname === '/api/deny' && req.method === 'POST') {
    const body = await readBody(req);
    const feedback = body.feedback || 'Plan changes requested';
    sendJson(res, 200, { ok: true });
    resolveDecision({
      approved: false,
      feedback: feedback,
    });
    return;
  }

  // Serve UI HTML for all other routes (SPA pattern)
  sendHtml(res);
});

// -- Start with retry logic -----------------------------------------------

async function startServer(attempt) {
  return new Promise((resolve, reject) => {
    server.once('error', (err) => {
      if (err.code === 'EADDRINUSE' && attempt < MAX_RETRIES) {
        process.stderr.write(
          `Port ${PORT} in use, retrying (${attempt}/${MAX_RETRIES})...\n`
        );
        setTimeout(() => {
          startServer(attempt + 1).then(resolve).catch(reject);
        }, RETRY_DELAY_MS);
      } else if (err.code === 'EADDRINUSE') {
        reject(new Error(`Port ${PORT} in use after ${MAX_RETRIES} retries`));
      } else {
        reject(err);
      }
    });

    server.listen(PORT, '0.0.0.0', () => {
      resolve();
    });
  });
}

async function main() {
  try {
    await startServer(1);
  } catch (err) {
    process.stderr.write(`Failed to start server: ${err.message}\n`);
    process.exit(1);
  }

  process.stderr.write(`Plannotator server listening on http://localhost:${PORT}\n`);

  // Block until user makes a decision
  const result = await decisionPromise;

  // Give browser time to receive the response
  await new Promise((r) => setTimeout(r, 1500));

  // Close server
  server.close();

  // Output hook JSON to stdout
  if (result.approved) {
    const output = {
      hookSpecificOutput: {
        hookEventName: 'PermissionRequest',
        decision: {
          behavior: 'allow',
        },
      },
    };

    if (result.permissionMode) {
      output.hookSpecificOutput.decision.updatedPermissions = [
        {
          type: 'setMode',
          mode: result.permissionMode,
          destination: 'session',
        },
      ];
    }

    process.stdout.write(JSON.stringify(output) + '\n');
  } else {
    const output = {
      hookSpecificOutput: {
        hookEventName: 'PermissionRequest',
        decision: {
          behavior: 'deny',
          message: result.feedback || 'Plan changes requested',
        },
      },
    };

    process.stdout.write(JSON.stringify(output) + '\n');
  }

  process.exit(0);
}

main();
