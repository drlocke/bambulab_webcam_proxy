import { readFileSync } from 'node:fs';

const DEFAULT_API_BASE_URL = 'https://api.bambulab.com';
const DEFAULT_CLIENT_HEADERS = {
  'User-Agent': 'bambu_network_agent/01.09.05.01',
  'X-BBL-Client-Name': 'OrcaSlicer',
  'X-BBL-Client-Type': 'slicer',
  'X-BBL-Client-Version': '01.09.05.51',
  'X-BBL-Language': 'en-US',
  'X-BBL-OS-Type': 'windows',
  'X-BBL-OS-Version': '10.0',
  'X-BBL-Agent-Version': '01.09.05.01',
  'X-BBL-Executable-info': '{}',
  'X-BBL-Agent-OS-Type': 'windows',
};

export class BambuApiError extends Error {
  constructor(message, status = 502, details = null) {
    super(message);
    this.name = 'BambuApiError';
    this.status = status;
    this.details = details;
  }
}

function firstValue(object, keys) {
  for (const key of keys) {
    if (object?.[key] !== undefined && object[key] !== null) return object[key];
  }
  return undefined;
}

function asBoolean(value, fallback = false) {
  if (typeof value === 'boolean') return value;
  if (typeof value === 'number') return value !== 0;
  if (typeof value === 'string') return ['true', 'online', '1'].includes(value.toLowerCase());
  return fallback;
}

function unwrap(body) {
  return body?.data ?? body?.result ?? body;
}

export function normalizeLogin(body) {
  const value = unwrap(body);
  const accessToken = firstValue(value, ['accessToken', 'access_token', 'token']);
  if (!accessToken) {
    const challenge = firstValue(value, ['challenge', 'loginType', 'verificationType']);
    if (challenge) return { challenge: String(challenge) };
    throw new BambuApiError('Bambu login did not return an access token.', 502);
  }

  return {
    accessToken: String(accessToken),
    refreshToken: firstValue(value, ['refreshToken', 'refresh_token']) ?? null,
    expiresIn: Number(firstValue(value, ['expiresIn', 'expires_in'])) || null,
    region: firstValue(value, ['region', 'userRegion', 'user_region']) ?? null,
  };
}

export function normalizePrinters(body) {
  const value = unwrap(body);
  const devices = Array.isArray(value) ? value : value?.devices ?? value?.printers ?? value?.binds ?? [];

  return devices
    .map((device) => {
      const id = firstValue(device, ['dev_id', 'devId', 'device_id', 'id']);
      if (!id) return null;
      const onlineValue = firstValue(device, ['online', 'dev_online', 'device_online', 'isOnline', 'status']);
      return {
        id: String(id),
        name: String(firstValue(device, ['name', 'dev_name', 'device_name', 'nickname']) ?? id),
        model: String(firstValue(device, ['dev_model_name', 'dev_product_name', 'model', 'product_name']) ?? ''),
        online: asBoolean(onlineValue, true),
        firmware: String(firstValue(device, ['dev_ver', 'firmware', 'firmware_version', 'ota_version']) ?? ''),
      };
    })
    .filter(Boolean)
    .sort((left, right) => Number(right.online) - Number(left.online) || left.name.localeCompare(right.name));
}

export function normalizeTicket(body) {
  const value = unwrap(body);
  const ticket = {
    uid: firstValue(value, ['ttcode', 'uid']),
    authkey: firstValue(value, ['authkey', 'authKey']),
    passwd: firstValue(value, ['passwd', 'password']),
    region: firstValue(value, ['region', 'userRegion', 'user_region']),
  };
  if (!ticket.uid || !ticket.authkey || !ticket.passwd) {
    throw new BambuApiError('Bambu did not return complete camera credentials.', 502);
  }
  return ticket;
}

export function buildCameraDescriptor(ticket, printer, client) {
  const region = ticket.region ?? client.region;
  if (!region) throw new BambuApiError('Camera region is unavailable. Configure BambuRegion.', 422);

  const query = new URLSearchParams({
    uid: ticket.uid,
    authkey: ticket.authkey,
    passwd: ticket.passwd,
    region,
  });
  const optional = {
    device: printer.id,
    net_ver: client.networkVersion,
    dev_ver: printer.firmware,
    cli_id: client.id,
    cli_ver: client.version,
  };
  for (const [key, value] of Object.entries(optional)) {
    if (value) query.set(key, value);
  }
  return `bambu:///tutk?${query.toString()}`;
}

export function readCachedCameraDescriptor(filePath, printerId) {
  const descriptor = readFileSync(filePath, 'utf8').trim();
  if (!descriptor || descriptor.length > 8192) throw new Error('Camera descriptor cache is invalid.');

  const url = new URL(descriptor);
  if (url.protocol !== 'bambu:' || !['/tutk', '/agora'].includes(url.pathname)) {
    throw new Error('Camera descriptor cache uses an unsupported protocol.');
  }
  if (url.searchParams.get('device') !== printerId) {
    throw new Error('Camera descriptor cache belongs to another printer.');
  }
  return descriptor;
}

export class BambuClient {
  constructor({ apiBaseUrl = DEFAULT_API_BASE_URL, fetchImpl = fetch, clientHeaders = DEFAULT_CLIENT_HEADERS } = {}) {
    this.apiBaseUrl = apiBaseUrl.replace(/\/$/, '');
    this.fetchImpl = fetchImpl;
    this.clientHeaders = clientHeaders;
  }

  async request(path, { method = 'GET', token, body, headers = {} } = {}) {
    const response = await this.fetchImpl(`${this.apiBaseUrl}${path}`, {
      method,
      headers: {
        ...this.clientHeaders,
        Accept: 'application/json',
        ...(body ? { 'Content-Type': 'application/json' } : {}),
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        ...headers,
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      const errorPayload = unwrap(payload);
      const apiMessage = firstValue(errorPayload, ['message', 'msg', 'error']);
      const message = apiMessage === undefined || apiMessage === null || String(apiMessage).trim() === ''
        ? `Bambu API returned HTTP ${response.status}.`
        : String(apiMessage);
      throw new BambuApiError(message, response.status === 401 ? 401 : 502, {
        upstreamStatus: response.status,
        upstreamCode: firstValue(errorPayload, ['code', 'statusCode']) ?? null,
        responseKeys: errorPayload && typeof errorPayload === 'object' ? Object.keys(errorPayload).sort() : [],
        contentType: response.headers.get('content-type')?.split(';', 1)[0] ?? null,
        cloudflare: response.headers.has('cf-ray') || response.headers.get('server')?.toLowerCase() === 'cloudflare',
      });
    }
    return payload;
  }

  async login(account, password) {
    return normalizeLogin(await this.request('/v1/user-service/user/login', {
      method: 'POST',
      body: { account, password },
    }));
  }

  async loginWithCode(account, code) {
    return normalizeLogin(await this.request('/v1/user-service/user/login', {
      method: 'POST',
      body: { account, code },
    }));
  }

  async listPrinters(token) {
    return normalizePrinters(await this.request('/v1/iot-service/api/user/bind', { token }));
  }

  async getTicket(token, printerId, clientId) {
    return normalizeTicket(await this.request('/v1/iot-service/api/user/ttcode', {
      method: 'POST',
      token,
      body: { dev_id: printerId },
      headers: clientId ? { 'X-BBL-Device-ID': clientId } : {},
    }));
  }
}