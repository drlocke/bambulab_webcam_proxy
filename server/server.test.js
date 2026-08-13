import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import test from 'node:test';

function listen(server) {
  return new Promise((resolveListen) => server.listen(0, '127.0.0.1', () => resolveListen(server.address().port)));
}

function close(server) {
  return new Promise((resolveClose) => server.close(resolveClose));
}

async function waitFor(url) {
  let lastError;
  for (let attempt = 0; attempt < 40; attempt += 1) {
    try {
      const response = await fetch(url);
      if (response.ok) return;
    } catch (error) {
      lastError = error;
    }
    await new Promise((resolveWait) => setTimeout(resolveWait, 50));
  }
  throw lastError ?? new Error(`Timed out waiting for ${url}`);
}

test('persists an opaque browser session and returns sanitized, online-first printers', async (context) => {
  const temporaryDirectory = mkdtempSync(join(tmpdir(), 'bambu-proxy-test-'));
  const mockApi = createServer(async (request, response) => {
    const body = await new Promise((resolveBody) => {
      let value = '';
      request.on('data', (chunk) => { value += chunk; });
      request.on('end', () => resolveBody(value ? JSON.parse(value) : {}));
    });
    response.setHeader('Content-Type', 'application/json');
    if (request.url === '/v1/user-service/user/login' && body.password === 'test-password') {
      return response.end(JSON.stringify({ accessToken: 'secret-token', region: 'us' }));
    }
    if (request.url === '/v1/user-service/user/login' && body.code === '123456') {
      return response.end(JSON.stringify({ accessToken: 'secret-token', region: 'us' }));
    }
    if (request.url === '/v1/iot-service/api/user/bind' && request.headers.authorization === 'Bearer secret-token') {
      return response.end(JSON.stringify({ devices: [
        { dev_id: 'two', name: 'Offline printer', online: false, dev_access_code: 'never-return-this' },
        { dev_id: 'one', name: 'Online printer', online: true },
      ] }));
    }
    response.statusCode = 401;
    return response.end(JSON.stringify({ message: 'Unauthorized' }));
  });
  const apiPort = await listen(mockApi);
  const portProbe = createServer();
  const servicePort = await listen(portProbe);
  await close(portProbe);
  const configPath = join(temporaryDirectory, 'config.json');
  writeFileSync(configPath, JSON.stringify({
    port: servicePort,
    runtimeDirectory: temporaryDirectory,
    cameraToolsPath: temporaryDirectory,
    apiBaseUrl: `http://127.0.0.1:${apiPort}`,
    region: 'us',
    clientVersion: 'test',
    networkVersion: 'test',
    sessionSecret: 'test-session-secret',
    secureCookies: false,
  }));
  const service = spawn(process.execPath, [resolve('server/server.js'), configPath], { stdio: 'pipe' });
  context.after(async () => {
    service.kill('SIGTERM');
    await close(mockApi);
    rmSync(temporaryDirectory, { recursive: true, force: true });
  });
  await waitFor(`http://127.0.0.1:${servicePort}/api/config`);

  const login = await fetch(`http://127.0.0.1:${servicePort}/api/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ account: 'person@example.com', password: 'test-password' }),
  });
  assert.equal(login.status, 202);
  assert.deepEqual(await login.json(), { codeRequired: true });

  const verification = await fetch(`http://127.0.0.1:${servicePort}/api/auth/code`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ account: 'person@example.com', code: '123456' }),
  });
  assert.equal(verification.status, 200);
  const cookie = verification.headers.get('set-cookie').split(';')[0];
  assert.match(cookie, /^bambu_session=[A-Za-z0-9_-]+$/);

  const restored = await fetch(`http://127.0.0.1:${servicePort}/api/session`, { headers: { Cookie: cookie } });
  assert.deepEqual(await restored.json(), { authenticated: true, account: 'person@example.com' });
  const printers = await fetch(`http://127.0.0.1:${servicePort}/api/printers`, { headers: { Cookie: cookie } });
  const result = await printers.json();
  assert.deepEqual(result.printers.map((printer) => [printer.name, printer.online]), [
    ['Online printer', true],
    ['Offline printer', false],
  ]);
  assert.equal(JSON.stringify(result).includes('never-return-this'), false);

  const encryptedSessions = readFileSync(join(temporaryDirectory, 'server', 'sessions.enc'), 'utf8');
  assert.equal(encryptedSessions.includes('test-password'), false);
  assert.equal(encryptedSessions.includes('secret-token'), false);
});