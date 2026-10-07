import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ControlAdmin, adminID, announcementText } from '../src/control-admin.js';
function fixture() {
  const documents = new Map(), sent = [], changes = []; let serial = 0;
  const snapshot = key => ({ exists: documents.has(key), get: field => documents.get(key)?.[field], data: () => documents.get(key), id: key.split('/').at(-1) });
  const ref = key => ({ key, get: async () => snapshot(key), update: async value => documents.set(key, { ...documents.get(key), ...value }) });
  const db = { doc: ref, collection: key => ({ doc: () => ref(key + '/event-' + ++serial), add: async value => documents.set(key + '/event-' + ++serial, value) }), runTransaction: async callback => {
    const updates = []; const result = await callback({ get: async r => snapshot(r.key), set: (r, value) => updates.push([r.key, value]), update: (r, value) => updates.push([r.key, { ...documents.get(r.key), ...value }]) });
    for (const [key, value] of updates) documents.set(key, value); return result;
  } };
  const auth = { verifyIdToken: async (token, revoked) => { assert.equal(revoked, true); return { uid: token }; }, updateUser: async (uid, value) => changes.push([uid, value]), revokeRefreshTokens: async uid => changes.push(['revoke', uid]) };
  const service = new ControlAdmin({ adminUIDs: ['owner'] }, { db, auth, stamp: () => 'server-time', messaging: { sendEach: async batch => { sent.push(...batch); return { successCount: batch.length, failureCount: 0 }; } } });
  return { service, documents, sent, changes };
}
test('administration rechecks revoked tokens, rejects listeners, and never disables its own administrators', async () => {
  const { service, changes } = fixture();
  assert.equal(await service.actor('owner'), 'owner'); await assert.rejects(service.actor('listener'), { statusCode: 403 });
  await assert.rejects(service.setUser('owner', 'owner', { disabled: true }), { statusCode: 400 });
  await assert.rejects(service.setUser('owner', 'listener', { disabled: true, admin: true }), { statusCode: 400 });
  await service.setUser('owner', 'listener', { disabled: true }); assert.deepEqual(changes, [['listener', { disabled: true }], ['revoke', 'listener']]);
});
test('global message hiding and restoration preserve sender and timestamp with a private audit record', async () => {
  const { service, documents } = fixture(); documents.set('globalMessages/message1', { senderID: 'listener', text: 'Original message', createdAt: 'original-time' });
  await service.moderate('owner', 'message1'); assert.deepEqual(documents.get('globalMessages/message1'), { senderID: 'listener', text: '[Message removed by moderator]', createdAt: 'original-time' });
  await service.moderate('owner', 'message1', true); assert.equal(documents.get('globalMessages/message1').text, 'Original message');
  await assert.rejects(service.moderate('owner', 'message1', true), { statusCode: 400 });
  assert.equal([...documents.keys()].filter(key => key.startsWith('controlCenterAudit/')).length, 2);
});
test('announcements remain private as drafts and publish through the existing cross-platform Global Chat schema', async () => {
  const { service, documents } = fixture(); const content = { title: 'News', body: 'Hello listeners', published: false };
  await service.saveAnnouncement('owner', 'news', content); assert.equal(documents.has('globalMessages/announcement-news'), false);
  await service.saveAnnouncement('owner', 'news', { ...content, published: true });
  assert.deepEqual(documents.get('globalMessages/announcement-news'), { senderID: 'owner', text: '📣 News\n\nHello listeners', createdAt: 'server-time' });
  await service.saveAnnouncement('owner', 'news', content); assert.equal(documents.get('globalMessages/announcement-news').text, '[Announcement withdrawn]');
});
test('manual push is idempotent, excludes the admin, and uses the existing opted-in Android payload', async () => {
  const { service, sent } = fixture(); service.pushRecipients = async () => [{ uid: 'owner', token: 'self' }, { uid: 'listener', token: 'device' }];
  const value = { id: 'request1', title: 'CapyFlow news', body: 'New banners available' };
  assert.deepEqual(await service.sendPush('owner', value), { id: 'request1', success: 1, failed: 0 });
  assert.equal((await service.sendPush('owner', value)).alreadySent, true); assert.equal(sent.length, 1); assert.equal(sent[0].data.kind, 'global');
  assert.equal(sent[0].data.recipientID, 'listener'); assert.equal(sent[0].token, 'device');
});
test('IDs and announcement lengths are bounded before any database work', () => {
  for (const value of ['../users', 'a/b', '', 'x'.repeat(129)]) assert.throws(() => adminID(value));
  assert.throws(() => announcementText({ title: 'Title', body: 'x'.repeat(3501) }));
});
test('revoked administrator sessions produce an authentication challenge', async () => {
  const { service } = fixture(); service.dependencies.auth.verifyIdToken = async () => { throw Object.assign(Error('Revoked'), { code: 'auth/id-token-revoked' }); };
  await assert.rejects(service.actor('owner'), { statusCode: 401 });
});
test('an announcement cannot take over a normal user message with a colliding ID', async () => {
  const { service, documents } = fixture(); documents.set('globalMessages/announcement-news', { senderID: 'listener', text: 'User message', createdAt: 'original-time' });
  await assert.rejects(service.saveAnnouncement('owner', 'news', { title: 'News', body: 'Announcement', published: true }), { statusCode: 409 });
  assert.equal(documents.get('globalMessages/announcement-news').text, 'User message');
  assert.equal(documents.has('controlCenterAnnouncements/news'), false);
});
