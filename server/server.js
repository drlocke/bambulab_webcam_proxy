import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { BambuApiError, BambuClient, buildCameraDescriptor, readCachedCameraDescriptor } from './bambu.js';
import { SessionStore } from './sessions.js';
import { StreamManager } from './streams.js';

const configPath = process.argv[2];
if (!configPath) throw new Error('Usage: node server/server.js <config.json>');
const config = JSON.parse(readFileSync(resolve(configPath), 'utf8'));
const bambu = new BambuClient({ apiBaseUrl: config.apiBaseUrl });
const sessions = new SessionStore(config.runtimeDirectory, config.sessionSecret);
const streams = new StreamManager({
  cameraToolsPath: config.cameraToolsPath,
  runtimeDirectory: config.runtimeDirectory,
});

function send(response, status, body, headers = {}) {
  const payload = body === null ? '' : JSON.stringify(body);
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'Content-Length': Buffer.byteLength(payload),
    ...headers,
  });
  response.end(payload);
}

async function readJson(request) {
  let body = '';
  for await (const chunk of request) {
    body += chunk;
    if (body.length > 16_384) throw Object.assign(new Error('Request body is too large.'), { status: 413 });
  }
  if (!body) return {};
  try {
    return JSON.parse(body);
  } catch {
    throw Object.assign(new Error('Request body must be valid JSON.'), { status: 400 });
  }
}

function requireSession(request) {
  const session = sessions.get(request);
  if (!session) throw Object.assign(new Error('Authentication required.'), { status: 401 });
  return session;
}

function validateMutation(request) {
  const fetchSite = request.headers['sec-fetch-site'];
  if (fetchSite && !['same-origin', 'none'].includes(fetchSite)) {
    throw Object.assign(new Error('Cross-site requests are not allowed.'), { status: 403 });
  }
}

async function loginWithPassword(request, response) {
  validateMutation(request);
  const body = await readJson(request);
  if (!body.account || !body.password) {
    throw Object.assign(new Error('Account and password are required.'), { status: 400 });
  }
  await bambu.login(body.account, body.password);
  return send(response, 202, { codeRequired: true });
}

async function loginWithCode(request, response) {
  validateMutation(request);
  const body = await readJson(request);
  if (!body.account || !body.code) {
    throw Object.assign(new Error('Account and verification code are required.'), { status: 400 });
  }
  const authentication = await bambu.loginWithCode(body.account, body.code);
  const session = sessions.create(body.account, authentication);
  return send(response, 200, {
    authenticated: true,
    account: session.account,
  }, { 'Set-Cookie': sessions.cookie(session, config.secureCookies) });
}

async function findOwnedPrinter(session, printerId) {
  const printers = await bambu.listPrinters(session.accessToken);
  const printer = printers.find((item) => item.id === printerId);
  if (!printer) throw Object.assign(new Error('Printer was not found on this account.'), { status: 404 });
  return printer;
}

const server = createServer(async (request, response) => {
  try {
    const url = new URL(request.url, 'http://127.0.0.1');
    const route = `${request.method} ${url.pathname}`;

    if (route === 'GET /api/config') return send(response, 200, { mode: 'multi' });
    if (route === 'GET /api/session') {
      const session = sessions.get(request);
      return send(response, 200, session
        ? { authenticated: true, account: session.account }
        : { authenticated: false });
    }
    if (route === 'POST /api/auth/login') return await loginWithPassword(request, response);
    if (route === 'POST /api/auth/code') return await loginWithCode(request, response);
    if (route === 'DELETE /api/session') {
      validateMutation(request);
      const session = sessions.get(request);
      if (session) streams.stopOwner(session.id);
      sessions.delete(session);
      return send(response, 204, null, { 'Set-Cookie': sessions.clearCookie(config.secureCookies) });
    }
    if (route === 'GET /api/printers') {
      const session = requireSession(request);
      return send(response, 200, { printers: await bambu.listPrinters(session.accessToken) });
    }
    if (route === 'GET /api/streams') {
      const session = requireSession(request);
      return send(response, 200, { streams: streams.list(session.id) });
    }
    if (route === 'POST /api/streams') {
      validateMutation(request);
      const session = requireSession(request);
      const { printerId } = await readJson(request);
      if (!printerId) throw Object.assign(new Error('printerId is required.'), { status: 400 });
      const printer = await findOwnedPrinter(session, printerId);
      if (!printer.online) throw Object.assign(new Error('Printer is offline.'), { status: 409 });
      const stream = streams.start(session.id, printer, async () => {
        try {
          const ticket = await bambu.getTicket(session.accessToken, printer.id, session.clientId);
          return buildCameraDescriptor(ticket, printer, {
            id: session.clientId,
            region: session.region || config.region,
            version: config.clientVersion,
            networkVersion: config.networkVersion,
          });
        } catch (error) {
          if (error?.details?.upstreamStatus !== 403 || error.details?.upstreamCode !== 8 || !config.cameraUrlFile) throw error;
          try {
            return readCachedCameraDescriptor(config.cameraUrlFile, printer.id);
          } catch {
            throw error;
          }
        }
      });
      return send(response, 202, stream);
    }
    const streamMatch = url.pathname.match(/^\/api\/streams\/([^/]+)$/);
    if (streamMatch && request.method === 'GET') {
      const session = requireSession(request);
      const stream = streams.get(session.id, streamMatch[1]);
      return stream ? send(response, 200, stream) : send(response, 404, { error: 'Stream not found.' });
    }
    if (streamMatch && request.method === 'DELETE') {
      validateMutation(request);
      const session = requireSession(request);
      return streams.stop(session.id, streamMatch[1])
        ? send(response, 204, null)
        : send(response, 404, { error: 'Stream not found.' });
    }
    return send(response, 404, { error: 'Not found.' });
  } catch (error) {
    const status = error.status ?? (error instanceof BambuApiError ? error.status : 500);
    if (status >= 500) console.error(`${new Date().toISOString()} ${error.name}: ${error.message}`);
    return send(response, status, { error: status >= 500 ? 'The camera service could not complete the request.' : error.message });
  }
});

server.listen(config.port, '127.0.0.1', () => {
  console.log(`Bambu multi-printer service listening on 127.0.0.1:${config.port}`);
});

function shutdown() {
  streams.stopAll();
  server.close(() => process.exit(0));
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);