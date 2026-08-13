import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { BambuClient, buildCameraDescriptor, normalizeLogin, normalizePrinters, normalizeTicket, readCachedCameraDescriptor } from './bambu.js';

test('normalizes common Bambu response variants without exposing raw device data', () => {
  assert.deepEqual(normalizeLogin({ accessToken: 'token', expiresIn: 3600 }), {
    accessToken: 'token', refreshToken: null, expiresIn: 3600, region: null,
  });
  assert.deepEqual(normalizePrinters({ devices: [
    { dev_id: 'offline', name: 'Beta', online: false, dev_access_code: 'secret' },
    { dev_id: 'online', name: 'Alpha', online: true, dev_ver: '01.02' },
  ] }), [
    { id: 'online', name: 'Alpha', model: '', online: true, firmware: '01.02' },
    { id: 'offline', name: 'Beta', model: '', online: false, firmware: '' },
  ]);
  assert.deepEqual(normalizeTicket({ data: { ttcode: 'uid', authkey: 'key', passwd: 'pass' } }), {
    uid: 'uid', authkey: 'key', passwd: 'pass', region: undefined,
  });
});

test('builds an encoded TUTK descriptor with the BambuSource client fingerprint', () => {
  const descriptor = buildCameraDescriptor(
    { uid: 'uid/1', authkey: 'key+1', passwd: 'secret', region: 'us' },
    { id: 'device-1', firmware: '01.02.03' },
    { id: 'client-id', version: '02.03.00', networkVersion: '00.00.32.00' },
  );
  const url = new URL(descriptor);
  assert.equal(url.protocol, 'bambu:');
  assert.equal(url.searchParams.get('uid'), 'uid/1');
  assert.equal(url.searchParams.get('device'), 'device-1');
  assert.equal(url.searchParams.get('cli_id'), 'client-id');
  assert.equal(url.searchParams.get('net_ver'), '00.00.32.00');
});

test('identifies cloud requests as a Bambu-compatible slicer client', async () => {
  let request;
  const client = new BambuClient({
    fetchImpl: async (url, options) => {
      request = { url, options };
      return new Response(JSON.stringify({ devices: [] }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      });
    },
  });

  await client.listPrinters('token');

  assert.equal(request.options.headers.Authorization, 'Bearer token');
  assert.equal(request.options.headers['X-BBL-Client-Type'], 'slicer');
  assert.match(request.options.headers['User-Agent'], /^bambu_network_agent\//);
});

test('binds camera ticket requests to the session client identifier', async () => {
  let headers;
  const client = new BambuClient({
    fetchImpl: async (_url, options) => {
      headers = options.headers;
      return new Response(JSON.stringify({ ttcode: 'uid', authkey: 'key', passwd: 'pass' }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      });
    },
  });

  await client.getTicket('token', 'printer', 'client-id');

  assert.equal(headers['X-BBL-Device-ID'], 'client-id');
});

test('accepts a cached camera descriptor only for its selected printer', () => {
  const directory = mkdtempSync(join(tmpdir(), 'bambu-camera-cache-'));
  const filePath = join(directory, 'url.txt');
  const descriptor = 'bambu:///tutk?uid=secret&authkey=secret&passwd=secret&device=printer-one';
  writeFileSync(filePath, descriptor);

  try {
    assert.equal(readCachedCameraDescriptor(filePath, 'printer-one'), descriptor);
    assert.throws(() => readCachedCameraDescriptor(filePath, 'printer-two'), /another printer/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});