import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { BambuClient } from './bambu.js';
import { SessionStore } from './sessions.js';

function shape(value, depth = 0) {
  if (depth > 3) return typeof value;
  if (Array.isArray(value)) return { type: 'array', length: value.length, item: value.length ? shape(value[0], depth + 1) : null };
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, shape(item, depth + 1)]));
  }
  return typeof value;
}

const config = JSON.parse(readFileSync(resolve(process.argv[2]), 'utf8'));
const sessions = new SessionStore(config.runtimeDirectory, config.sessionSecret);
const session = [...sessions.sessions.values()][0];
if (!session) throw new Error('No persisted login session is available.');

const client = new BambuClient({ apiBaseUrl: config.apiBaseUrl });
const printers = await client.listPrinters(session.accessToken);
const printer = printers.find((item) => item.online);
if (!printer) throw new Error('No online printer is available.');

try {
  const response = await client.request('/v1/iot-service/api/user/ttcode', {
    method: 'POST',
    token: session.accessToken,
    body: { dev_id: printer.id },
    headers: { 'X-BBL-Device-ID': session.clientId },
  });
  console.log(JSON.stringify({ responseShape: shape(response) }, null, 2));
} catch (error) {
  console.log(JSON.stringify({
    errorType: error?.name ?? typeof error,
    upstreamStatus: error?.details?.upstreamStatus ?? null,
    upstreamCode: error?.details?.upstreamCode ?? null,
    responseKeys: error?.details?.responseKeys ?? [],
    contentType: error?.details?.contentType ?? null,
    cloudflare: error?.details?.cloudflare ?? false,
  }, null, 2));
  process.exitCode = 1;
}