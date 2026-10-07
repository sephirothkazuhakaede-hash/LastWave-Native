import { test } from 'node:test';
import assert from 'node:assert/strict';
import { backendRoot, bannerID } from '../policy.js';
test('admin credentials only travel over HTTPS or loopback development', () => {
  assert.equal(backendRoot('https://example.com/v1/'), 'https://example.com');
  assert.equal(backendRoot('http://127.0.0.1:8787'), 'http://127.0.0.1:8787');
  for (const url of ['http://192.168.1.2:8787', 'https://user:secret@example.com', 'file:///tmp/server', 'https://example.com/?token=x']) assert.throws(() => backendRoot(url));
});
test('IDs cannot escape banner routes or use the default sentinel', () => {
  assert.equal(bannerID('capy-parade-v1'), 'capy-parade-v1');
  for (const id of ['../other', 'none', 'UPPER', 'a/b', 'x'.repeat(65)]) assert.throws(() => bannerID(id));
});
