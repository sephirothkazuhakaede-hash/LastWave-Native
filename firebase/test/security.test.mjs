import { readFile } from 'node:fs/promises';
import { before, after, beforeEach, test } from 'node:test';
import { initializeTestEnvironment, assertSucceeds, assertFails } from '@firebase/rules-unit-testing';
import { doc, setDoc, updateDoc, getDoc, writeBatch, serverTimestamp, Bytes, Timestamp } from 'firebase/firestore';

let env;
before(async () => {
  env = await initializeTestEnvironment({ projectId: 'demo-capyflow', firestore: {
    rules: await readFile(new URL('../firestore.rules', import.meta.url), 'utf8'),
  }});
});
after(async () => { await env?.cleanup(); });
beforeEach(async () => { await env.clearFirestore(); });

const account = uid => env.authenticatedContext(uid).firestore();
const profile = username => ({ username, usernameKey: username, usernameIsGenerated: true,
  displayName: 'Listener', bio: '', avatarURL: '', createdAt: serverTimestamp(), updatedAt: serverTimestamp() });
async function create(uid, username) {
  const db = account(uid), batch = writeBatch(db);
  batch.set(doc(db, 'profiles', uid), profile(username));
  batch.set(doc(db, 'usernames', username), { uid, createdAt: serverTimestamp() });
  await assertSucceeds(batch.commit());
}
async function rename(uid, oldName, newName) {
  const db = account(uid), batch = writeBatch(db);
  batch.update(doc(db, 'profiles', uid), { username: newName, usernameKey: newName,
    usernameIsGenerated: false, usernameChangedAt: serverTimestamp(), updatedAt: serverTimestamp() });
  batch.delete(doc(db, 'usernames', oldName));
  batch.set(doc(db, 'usernames', newName), { uid, createdAt: serverTimestamp() });
  return batch.commit();
}

test('new profile, photo, first rename and uniqueness work; cooldown cannot be reset', async () => {
  await create('alice', 'alice_initial');
  await create('bob', 'bob_initial');
  await assertSucceeds(updateDoc(doc(account('alice'), 'profiles', 'alice'), { avatarData: Bytes.fromUint8Array(new Uint8Array(131072)) }));
  await assertFails(updateDoc(doc(account('alice'), 'profiles', 'alice'), { avatarData: Bytes.fromUint8Array(new Uint8Array(131073)) }));
  await assertSucceeds(rename('alice', 'alice_initial', 'alice_custom'));
  await assertFails(rename('alice', 'alice_custom', 'alice_second'));
  await assertFails(updateDoc(doc(account('alice'), 'profiles', 'alice'), { usernameIsGenerated: true }));
  await assertFails(rename('bob', 'bob_initial', 'alice_custom'));
  await assertFails(updateDoc(doc(account('bob'), 'profiles', 'alice'), { bio: 'attacker' }));
});

test('legacy profiles can migrate missing fields and repair a missing reservation atomically', async () => {
  await env.withSecurityRulesDisabled(async context => {
    await setDoc(doc(context.firestore(), 'profiles', 'alice'), { username: 'legacy_alice', displayName: 'Alice', createdAt: Timestamp.now() });
  });
  const db = account('alice'), batch = writeBatch(db);
  batch.update(doc(db, 'profiles', 'alice'), { usernameKey: 'legacy_alice', usernameIsGenerated: false,
    bio: '', avatarURL: '', updatedAt: serverTimestamp() });
  batch.set(doc(db, 'usernames', 'legacy_alice'), { uid: 'alice', createdAt: serverTimestamp() });
  await assertSucceeds(batch.commit());
  await assertSucceeds(rename('alice', 'legacy_alice', 'alice_custom'));
});

test('playlist access uses stable UIDs across username changes; outsiders cannot read or edit', async () => {
  await create('alice', 'alice_initial');
  await create('bob', 'bob_initial');
  const alice = account('alice'), bob = account('bob'), outsider = account('mallory');
  await assertSucceeds(setDoc(doc(alice, 'playlists', 'shared'), { ownerID: 'alice', memberIDs: ['alice'], name: 'Music', tracks: [] }));
  await assertFails(getDoc(doc(bob, 'playlists', 'shared')));
  await assertSucceeds(updateDoc(doc(alice, 'playlists', 'shared'), { memberIDs: ['alice', 'bob'] }));
  await assertSucceeds(rename('bob', 'bob_initial', 'bob_custom'));
  await assertSucceeds(updateDoc(doc(bob, 'playlists', 'shared'), { tracks: [{ id: 'song123', title: 'Song' }], updatedAt: serverTimestamp() }));
  await assertFails(updateDoc(doc(bob, 'playlists', 'shared'), { name: 'Hijacked' }));
  await assertFails(updateDoc(doc(bob, 'playlists', 'shared'), { memberIDs: ['bob', 'mallory'] }));
  await assertFails(getDoc(doc(outsider, 'playlists', 'shared')));
  await assertFails(updateDoc(doc(outsider, 'playlists', 'shared'), { tracks: [] }));
  await assertSucceeds(updateDoc(doc(bob, 'playlists', 'shared'), { memberIDs: ['alice'], updatedAt: serverTimestamp() }));
  await assertFails(getDoc(doc(bob, 'playlists', 'shared')));
  await assertFails(updateDoc(doc(alice, 'playlists', 'shared'), { memberIDs: [] }));
});

test('a partial profile without a username can bootstrap safely', async () => {
  await env.withSecurityRulesDisabled(async context => {
    await setDoc(doc(context.firestore(), 'profiles', 'alice'), { displayName: 'Existing name', bio: 'Existing bio' });
  });
  const db = account('alice'), batch = writeBatch(db);
  batch.set(doc(db, 'profiles', 'alice'), { ...profile('alice_initial'), displayName: 'Existing name', bio: 'Existing bio' }, { merge: true });
  batch.set(doc(db, 'usernames', 'alice_initial'), { uid: 'alice', createdAt: serverTimestamp() });
  await assertSucceeds(batch.commit());
  await assertSucceeds(rename('alice', 'alice_initial', 'alice_custom'));
});

test('repairing a conflicting legacy profile never deletes another users reservation', async () => {
  await create('bob', 'shared_name');
  await env.withSecurityRulesDisabled(async context => {
    await setDoc(doc(context.firestore(), 'profiles', 'alice'), {
      username: 'shared_name', usernameKey: 'shared_name', usernameIsGenerated: false,
      displayName: 'Alice', bio: '', avatarURL: '',
    });
  });
  const db = account('alice'), batch = writeBatch(db);
  batch.update(doc(db, 'profiles', 'alice'), { username: 'alice_fixed', usernameKey: 'alice_fixed',
    usernameIsGenerated: false, usernameChangedAt: serverTimestamp() });
  batch.set(doc(db, 'usernames', 'alice_fixed'), { uid: 'alice', createdAt: serverTimestamp() });
  await assertSucceeds(batch.commit());
  await assertSucceeds(getDoc(doc(account('bob'), 'usernames', 'shared_name')));
});
