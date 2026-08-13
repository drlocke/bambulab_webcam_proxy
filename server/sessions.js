import { createCipheriv, createDecipheriv, createHash, randomBytes, randomUUID } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const SESSION_LIFETIME_MS = 30 * 24 * 60 * 60 * 1000;

function parseCookies(header = '') {
  return Object.fromEntries(header.split(';').map((part) => {
    const separator = part.indexOf('=');
    if (separator < 0) return [part.trim(), ''];
    return [part.slice(0, separator).trim(), decodeURIComponent(part.slice(separator + 1))];
  }).filter(([key]) => key));
}

export class SessionStore {
  constructor(runtimeDirectory, configuredSecret = '') {
    this.directory = join(runtimeDirectory, 'server');
    this.dataPath = join(this.directory, 'sessions.enc');
    this.keyPath = join(this.directory, 'session.key');
    mkdirSync(this.directory, { recursive: true });
    const secret = configuredSecret || this.loadOrCreateSecret();
    this.key = createHash('sha256').update(secret).digest();
    this.sessions = new Map();
    this.load();
  }

  loadOrCreateSecret() {
    if (existsSync(this.keyPath)) return readFileSync(this.keyPath, 'utf8').trim();
    const secret = randomBytes(48).toString('base64url');
    writeFileSync(this.keyPath, secret, { encoding: 'utf8', mode: 0o600 });
    return secret;
  }

  load() {
    if (!existsSync(this.dataPath)) return;
    try {
      const envelope = JSON.parse(readFileSync(this.dataPath, 'utf8'));
      const decipher = createDecipheriv('aes-256-gcm', this.key, Buffer.from(envelope.iv, 'base64'));
      decipher.setAuthTag(Buffer.from(envelope.tag, 'base64'));
      const plaintext = Buffer.concat([
        decipher.update(Buffer.from(envelope.data, 'base64')),
        decipher.final(),
      ]).toString('utf8');
      const now = Date.now();
      for (const session of JSON.parse(plaintext)) {
        if (session.expiresAt > now) this.sessions.set(session.id, session);
      }
    } catch {
      throw new Error('Unable to decrypt the saved sessions. Check MultiSessionSecret.');
    }
  }

  save() {
    const iv = randomBytes(12);
    const cipher = createCipheriv('aes-256-gcm', this.key, iv);
    const plaintext = JSON.stringify([...this.sessions.values()]);
    const data = Buffer.concat([cipher.update(plaintext, 'utf8'), cipher.final()]);
    const envelope = JSON.stringify({
      iv: iv.toString('base64'),
      tag: cipher.getAuthTag().toString('base64'),
      data: data.toString('base64'),
    });
    const temporaryPath = `${this.dataPath}.tmp`;
    writeFileSync(temporaryPath, envelope, { encoding: 'utf8', mode: 0o600 });
    renameSync(temporaryPath, this.dataPath);
  }

  create(account, authentication) {
    const session = {
      id: randomBytes(32).toString('base64url'),
      accountId: randomUUID(),
      account,
      accessToken: authentication.accessToken,
      refreshToken: authentication.refreshToken,
      region: authentication.region,
      clientId: randomUUID(),
      expiresAt: Date.now() + SESSION_LIFETIME_MS,
    };
    this.sessions.set(session.id, session);
    this.save();
    return session;
  }

  get(request) {
    const id = parseCookies(request.headers.cookie).bambu_session;
    if (!id) return null;
    const session = this.sessions.get(id);
    if (!session) return null;
    if (session.expiresAt <= Date.now()) {
      this.sessions.delete(id);
      this.save();
      return null;
    }
    return session;
  }

  delete(session) {
    if (!session) return;
    this.sessions.delete(session.id);
    this.save();
  }

  cookie(session, secure = false) {
    const maxAge = Math.floor((session.expiresAt - Date.now()) / 1000);
    return `bambu_session=${encodeURIComponent(session.id)}; Path=/; HttpOnly; SameSite=Strict; Max-Age=${maxAge}${secure ? '; Secure' : ''}`;
  }

  clearCookie(secure = false) {
    return `bambu_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0${secure ? '; Secure' : ''}`;
  }
}