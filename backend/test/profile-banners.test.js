import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { ProfileBannerStore, inspectGIF, authorizeBannerAdmin, MAX_GIF_BYTES } from '../src/profile-banners.js';
import { createServer } from '../src/server.js';

const header = Buffer.from('47494638396101000100800000000000ffffff', 'hex');
const frame = Buffer.from('21f904000a0000002c0000000001000100000202440100', 'hex');
const gif = Buffer.concat([header, frame, frame, Buffer.from([0x3b])]);
const setup = async () => { const root = await fs.mkdtemp(path.join(os.tmpdir(), 'capy-banners-')); return { root, store: new ProfileBannerStore(root) }; };

test('GIF validation rejects oversized, static, truncated and invalid-frame uploads', () => {
  assert.equal(inspectGIF(gif).frames, 2);
  for (const invalid of [Buffer.from('not a gif'), gif.subarray(0, -1), Buffer.concat([header, frame, Buffer.from([0x3b])]), Buffer.alloc(MAX_GIF_BYTES + 1)]) assert.throws(() => inspectGIF(invalid));
  const large = Buffer.from(gif); large.writeUInt16LE(4096, 6); assert.throws(() => inspectGIF(large));
});
test('drafts stay private, publishing survives restarts, unpublishing/deleting revoke selection and preserve tombstones', async () => {
  const { root, store } = await setup();
  try {
    const item = await store.upload('parade-two', 'Parade two', gif);
    assert.equal((await store.list()).length, 0);
    await assert.rejects(store.file(item.id, item.revision, false), { statusCode: 404 });
    assert.deepEqual(await store.file(item.id, item.revision, true), gif);
    const permissions = [];
    await store.update(item.id, { published: true }, async (id, published) => permissions.push([id, published]));
    assert.equal((await new ProfileBannerStore(root).list()).length, 1);
    await assert.rejects(store.update(item.id, { published: false }, async () => { throw Error('offline'); }));
    assert.equal((await store.list()).length, 1);
    await store.update(item.id, { published: false }, async (id, published) => permissions.push([id, published]));
    assert.equal((await store.list()).length, 0);
    await store.update(item.id, { deleted: true }, async () => {});
    await assert.rejects(store.file(item.id, item.revision, true), { statusCode: 404 });
    await assert.rejects(store.upload(item.id, 'Reuse removed ID', gif), { statusCode: 409 });
    assert.deepEqual(permissions, [[item.id, true], [item.id, false]]);
  } finally { await fs.rm(root, { recursive: true, force: true }); }
});
test('admin authorization is mandatory even with anonymous/local media access', async () => {
  const config = { authMode: 'local', allowAnonymousLan: true, adminUIDs: ['owner'] };
  const request = token => ({ headers: token ? { authorization: `Bearer ${token}` } : {}, socket: { remoteAddress: '127.0.0.1' } });
  const verifier = { verify: async token => { if (token === 'forged') throw Error('bad signature'); return { sub: token }; } };
  await assert.rejects(authorizeBannerAdmin(request(), config, verifier), { statusCode: 401 });
  await assert.rejects(authorizeBannerAdmin(request('listener'), config, verifier), { statusCode: 403 });
  await assert.rejects(authorizeBannerAdmin(request('forged'), config, verifier));
  assert.equal(await authorizeBannerAdmin(request('owner'), config, verifier), 'owner');
});
test('HTTP flow protects admin endpoints and serves only published immutable GIFs', async () => {
  const { root, store } = await setup();
  const server = createServer({ config: { authMode: 'local', adminUIDs: ['owner'] }, bannerStore: store,
    bannerPermissionMirror: async () => {}, tokenVerifier: { verify: async token => ({ sub: token }) },
    resolver: {}, cache: {}, timings: { record() {} }, logger: {} });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const admin = { Authorization: 'Bearer owner' };
  try {
    assert.equal((await fetch(base + '/v1/admin/banners')).status, 401);
    assert.equal((await fetch(base + '/v1/admin/banners', { headers: { Authorization: 'Bearer listener' } })).status, 403);
    const upload = await fetch(base + '/v1/admin/banners/test-banner?name=Test', { method: 'POST', headers: { ...admin, 'Content-Type': 'image/gif' }, body: gif });
    assert.equal(upload.status, 201); const item = await upload.json();
    assert.equal((await fetch(base + item.path)).status, 404);
    assert.equal((await fetch(base + '/v1/admin/banners/test-banner', { method: 'PATCH', headers: admin, body: JSON.stringify({ published: true }) })).status, 200);
    const catalog = await (await fetch(base + '/v1/profile-banners')).json(); assert.equal(catalog.banners[0].id, item.id);
    const media = await fetch(base + item.path); assert.equal(media.headers.get('content-type'), 'image/gif');
    assert.deepEqual(Buffer.from(await media.arrayBuffer()), gif);
    assert.equal((await fetch(base + '/v1/admin/banners/test-banner', { method: 'DELETE', headers: admin })).status, 200);
    assert.equal((await fetch(base + item.path)).status, 404);
  } finally { await new Promise(resolve => server.close(resolve)); await fs.rm(root, { recursive: true, force: true }); }
});
