// HTTP wrapper for the isolated four-frame renderer.
// The process is intentionally small: one request is rendered at a time and
// the caller receives only the validated JSON produced by capture.mjs.
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HOST = process.env.QUALITY_RENDERER_HOST || '0.0.0.0';
const PORT = Number(process.env.QUALITY_RENDERER_PORT || 8080);
const MAX_DOCUMENT_BYTES = 1024 * 1024;
const MAX_OUTPUT_BYTES = 8 * 1024 * 1024;
const TIMEOUT_MS = 250_000;
const ROOT = dirname(fileURLToPath(import.meta.url));
const CAPTURE = join(ROOT, 'capture.mjs');

let active = false;

function json(res, status, value) {
  const body = JSON.stringify(value);
  res.writeHead(status, {
    'content-type': 'application/json',
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
    'content-length': Buffer.byteLength(body),
  });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    let tooLarge = false;
    req.on('data', chunk => {
      size += chunk.length;
      if (size > MAX_DOCUMENT_BYTES) {
        tooLarge = true;
        return;
      }
      if (tooLarge) return;
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (tooLarge) reject(new Error('document too large'));
      else resolve(Buffer.concat(chunks).toString('utf8'));
    });
    req.on('error', reject);
  });
}

function render(document) {
  if (active) return Promise.reject(new Error('renderer busy'));
  active = true;
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [CAPTURE], {
      cwd: ROOT,
      stdio: ['pipe', 'pipe', 'ignore'],
      env: { ...process.env },
    });
    const output = [];
    let size = 0;
    let settled = false;
    const finish = (err, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      active = false;
      if (err) reject(err); else resolve(value);
    };
    const timer = setTimeout(() => {
      child.kill('SIGKILL');
      finish(new Error('renderer timeout'));
    }, TIMEOUT_MS);
    child.stdout.on('data', chunk => {
      size += chunk.length;
      if (size > MAX_OUTPUT_BYTES) {
        child.kill('SIGKILL');
        finish(new Error('renderer output too large'));
        return;
      }
      output.push(chunk);
    });
    child.on('error', err => finish(err));
    child.on('close', code => {
      if (code !== 0) {
        finish(new Error('renderer failed'));
        return;
      }
      try {
        const value = JSON.parse(Buffer.concat(output).toString('utf8'));
        if (!Array.isArray(value) || value.length !== 4) throw new Error('invalid renderer output');
        finish(null, value);
      } catch (err) {
        finish(err);
      }
    });
    child.stdin.end(document);
  });
}

const server = createServer(async (req, res) => {
  if (req.method === 'GET' && req.url === '/health') {
    json(res, 200, { status: 'ok' });
    return;
  }
  if (req.method !== 'POST' || req.url !== '/render') {
    json(res, 404, { message: 'not found' });
    return;
  }
  if (active) {
    json(res, 429, { message: 'renderer busy' });
    return;
  }
  try {
    const document = await readBody(req);
    const frames = await render(document);
    json(res, 200, frames);
  } catch (error) {
    const message = error?.message === 'document too large' ? error.message : 'renderer failed';
    json(res, message === 'document too large' ? 413 : 502, { message });
  }
});

server.headersTimeout = 10_000;
server.requestTimeout = TIMEOUT_MS + 10_000;
server.listen(PORT, HOST, () => {
  process.stdout.write(`quality renderer listening on ${HOST}:${PORT}\n`);
});
