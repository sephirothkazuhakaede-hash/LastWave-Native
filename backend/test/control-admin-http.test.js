import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from '../src/server.js';
test('all admin modules require verified allowlisted tokens and bounded privileged operations', async () => {
  const calls = [];
  const controlAdmin = { actor: async token => { calls.push(['actor', token]); return token; }, users: async query => ({ users: [], query }), messages: async () => ({ messages: [] }), announcements: async () => ({ announcements: [] }), pushPreview: async () => ({ androidDevices: 0 }), history: async () => ({ events: [] }), setUser: async (actor, uid, patch) => { calls.push(['setUser', actor, uid, patch]); return { uid }; } };
  const server = createServer({ config: { authMode: 'local', adminUIDs: ['owner'] }, resolver: {}, cache: { stats: async () => ({ entries: 0 }) }, timings: { record() {} }, bannerStore: { list: async () => [] }, tokenVerifier: { verify: async token => ({ sub: token }) }, controlAdmin, logger: {} });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve)); const root = `http://127.0.0.1:${server.address().port}`;
  try {
    for (const route of ['users', 'global-messages', 'announcements', 'push', 'audit']) {
      assert.equal((await fetch(`${root}/v1/admin/${route}`)).status, 401);
      assert.equal((await fetch(`${root}/v1/admin/${route}`, { headers: { Authorization: 'Bearer listener' } })).status, 403);
      assert.equal((await fetch(`${root}/v1/admin/${route}`, { headers: { Authorization: 'Bearer owner' } })).status, 200);
    }
    assert.equal((await fetch(root + '/v1/admin/global-messages/id', { method: 'PATCH', headers: { Authorization: 'Bearer owner' }, body: JSON.stringify({ restore: true, senderID: 'forged' }) })).status, 400);
    const response = await fetch(root + '/v1/admin/users/listener', { method: 'PATCH', headers: { Authorization: 'Bearer owner' }, body: JSON.stringify({ disabled: true }) });
    assert.equal(response.status, 200); assert.deepEqual(calls.at(-1), ['setUser', 'owner', 'listener', { disabled: true }]);
    assert.equal((await fetch(root + '/v1/admin/users/listener', { method: 'PATCH', headers: { Authorization: 'Bearer owner' }, body: 'x'.repeat(20000) })).status, 413);
  } finally { await new Promise(resolve => server.close(resolve)); }
});
