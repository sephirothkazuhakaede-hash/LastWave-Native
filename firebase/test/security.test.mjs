import { readFile } from 'node:fs/promises';
import { before, after, beforeEach, test } from 'node:test';
import { initializeTestEnvironment, assertSucceeds, assertFails } from '@firebase/rules-unit-testing';
import { doc, setDoc, updateDoc, deleteDoc, getDoc, getDocs, collection, query, limit, where, documentId, writeBatch, runTransaction, serverTimestamp, Bytes, Timestamp } from 'firebase/firestore';

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

test('activity is opt-in and owner-only; privacy OFF removes presence atomically', async () => {
  const alice = account('alice'), bob = account('bob');
  const presence = { title: 'Song', artist: 'Artist', videoID: 'abcdefghijk', artworkURL: '',
    playing: true, updatedAt: serverTimestamp(), expiresAt: Timestamp.fromMillis(Date.now() + 300000) };
  await assertFails(setDoc(doc(alice, 'listeningActivity', 'alice'), presence));
  await assertSucceeds(setDoc(doc(alice, 'activitySettings', 'alice'), { sharing: true, updatedAt: serverTimestamp() }));
  await assertSucceeds(setDoc(doc(alice, 'listeningActivity', 'alice'), presence));
  await assertSucceeds(getDoc(doc(bob, 'listeningActivity', 'alice')));
  await assertFails(getDoc(doc(bob, 'activitySettings', 'alice')));
  await assertFails(setDoc(doc(bob, 'listeningActivity', 'alice'), presence));
  await assertFails(setDoc(doc(alice, 'listeningActivity', 'alice'), { ...presence, audio: 'payload' }));
  await assertFails(setDoc(doc(alice, 'listeningActivity', 'alice'), { ...presence, title: 'x'.repeat(301) }));
  await assertFails(setDoc(doc(alice, 'listeningActivity', 'alice'), { ...presence, expiresAt: Timestamp.fromMillis(Date.now() + 86400000) }));
  await assertFails(setDoc(doc(alice, 'activitySettings', 'alice'), { sharing: false, updatedAt: serverTimestamp() }));
  const batch = writeBatch(alice);
  batch.set(doc(alice, 'activitySettings', 'alice'), { sharing: false, updatedAt: serverTimestamp() });
  batch.delete(doc(alice, 'listeningActivity', 'alice'));
  await assertSucceeds(batch.commit());
  const removed = await assertSucceeds(getDoc(doc(bob, 'listeningActivity', 'alice')));
  if (removed.exists()) throw new Error('Privacy OFF must remove presence');
  await assertFails(setDoc(doc(alice, 'listeningActivity', 'alice'), presence));
});

test('activity preference bootstrap OFF works and followed-person query is allowed', async () => {
  const alice = account('alice'), bob = account('bob');
  const batch = writeBatch(alice);
  batch.set(doc(alice, 'activitySettings', 'alice'), { sharing: false, updatedAt: serverTimestamp() });
  batch.delete(doc(alice, 'listeningActivity', 'alice'));
  await assertSucceeds(batch.commit());
  await assertSucceeds(getDoc(doc(alice, 'activitySettings', 'alice')));
  await assertSucceeds(getDocs(query(collection(bob, 'listeningActivity'), where(documentId(), 'in', ['alice']), limit(20))));
  await assertFails(getDocs(collection(bob, 'listeningActivity')));
});

test('personal playlist backup survives a new account session and is private', async () => {
  const alice = account('alice');
  const path = ['users', 'alice', 'library', 'playlist_hash'];
  const payload = Bytes.fromUint8Array(new TextEncoder().encode(JSON.stringify({ id: 'playlist-1', name: 'My music', tracks: [{ id: 'abcdefghijk', title: 'Song', artist: 'Artist' }] })));
  await assertSucceeds(setDoc(doc(alice, ...path), { playlistID: 'playlist-1', deleted: false, payload, updatedAt: serverTimestamp() }));
  const reinstalled = account('alice');
  const restored = await assertSucceeds(getDoc(doc(reinstalled, ...path)));
  if (restored.data().payload.toBase64() !== payload.toBase64()) throw new Error('Playlist payload lost');
  await assertSucceeds(getDocs(collection(reinstalled, 'users', 'alice', 'library')));
  await assertFails(getDoc(doc(account('bob'), ...path)));
  await assertFails(setDoc(doc(account('bob'), ...path), { playlistID: 'playlist-1', deleted: true, updatedAt: serverTimestamp() }));
  await assertFails(setDoc(doc(alice, ...path), { playlistID: 'playlist-1', deleted: false, payload: Bytes.fromUint8Array(new Uint8Array(750001)), updatedAt: serverTimestamp() }));
  await assertSucceeds(setDoc(doc(alice, ...path), { playlistID: 'playlist-1', deleted: true, updatedAt: serverTimestamp() }));
  const deleted = await assertSucceeds(getDoc(doc(reinstalled, ...path)));
  if (!deleted.data().deleted) throw new Error('Deletion did not synchronize');
});


test('shared playlist owner can delete after removing all collaborators', async () => {
  const alice = account('alice'), bob = account('bob');
  await assertSucceeds(setDoc(doc(alice, 'playlists', 'orphaned'), { ownerID: 'alice', memberIDs: ['alice'], name: 'Old album', tracks: [] }));
  await assertSucceeds(updateDoc(doc(alice, 'playlists', 'orphaned'), { memberIDs: ['alice', 'bob'] }));
  await assertFails(deleteDoc(doc(bob, 'playlists', 'orphaned')));
  await assertSucceeds(updateDoc(doc(alice, 'playlists', 'orphaned'), { memberIDs: ['alice'] }));
  await assertSucceeds(deleteDoc(doc(alice, 'playlists', 'orphaned')));
});

async function message(uid, threadID, messageID, { first = false, text = 'Hello' } = {}) {
  const db = account(uid), batch = writeBatch(db);
  batch.set(doc(db, 'conversations', threadID, 'messages', messageID), { senderID: uid, text, createdAt: serverTimestamp() });
  if (first) batch.set(doc(db, 'conversations', threadID), { memberIDs: ['alice', 'bob'], lastMessageID: messageID, lastSenderID: uid,
    lastText: text, createdAt: serverTimestamp(), updatedAt: serverTimestamp(), readMessageIDs: { alice: uid === 'alice' ? messageID : '', bob: uid === 'bob' ? messageID : '' } });
  else batch.update(doc(db, 'conversations', threadID), { lastMessageID: messageID, lastSenderID: uid, lastText: text,
    updatedAt: serverTimestamp(), ['readMessageIDs.' + uid]: messageID });
  return batch.commit();
}

test('direct chats are participant-private, atomic and require following to start', async () => {
  const alice = account('alice'), bob = account('bob'), stranger = account('mallory');
  await assertSucceeds(getDoc(doc(alice, 'conversations', 'alice_bob')));
  await assertFails(getDoc(doc(stranger, 'conversations', 'alice_bob')));
  await assertFails(message('alice', 'alice_bob', 'first', { first: true }));
  await setDoc(doc(alice, 'follows', 'alice_bob'), { followerID: 'alice', followingID: 'bob' });
  await assertSucceeds(message('alice', 'alice_bob', 'first', { first: true }));
  await assertSucceeds(getDoc(doc(bob, 'conversations', 'alice_bob', 'messages', 'first')));
  await assertFails(getDoc(doc(stranger, 'conversations', 'alice_bob', 'messages', 'first')));
  await assertFails(getDocs(collection(stranger, 'conversations')));
  await assertSucceeds(getDocs(query(collection(bob, 'conversations'), where('memberIDs', 'array-contains', 'bob'), limit(50))));
  await assertSucceeds(getDocs(query(collection(bob, 'conversations', 'alice_bob', 'messages'), limit(50))));
  await assertFails(getDocs(collection(bob, 'conversations', 'alice_bob', 'messages')));
  await assertFails(updateDoc(doc(bob, 'conversations', 'alice_bob'), { memberIDs: ['bob', 'mallory'] }));
  await assertFails(updateDoc(doc(bob, 'conversations', 'alice_bob'), { 'readMessageIDs.alice': 'attacker' }));
  await assertSucceeds(updateDoc(doc(bob, 'conversations', 'alice_bob'), { 'readMessageIDs.bob': 'first' }));
  await assertFails(setDoc(doc(bob, 'conversations', 'alice_bob', 'messages', 'uncommitted'), { senderID: 'bob', text: 'Fake', createdAt: serverTimestamp() }));
  await assertFails(message('bob', 'alice_bob', 'huge', { text: 'x'.repeat(4001) }));
  await assertFails(message('bob', 'alice_bob', 'empty', { text: '' }));
  await assertSucceeds(message('bob', 'alice_bob', 'reply'));
  await assertFails(updateDoc(doc(bob, 'conversations', 'alice_bob', 'messages', 'reply'), { text: 'Changed' }));
  await assertFails(deleteDoc(doc(bob, 'conversations', 'alice_bob', 'messages', 'reply')));
});

const google = uid => env.authenticatedContext(uid, { firebase: { sign_in_provider: 'google.com' } }).firestore();
function globalSend(db, uid, id, text = 'Hello everyone') {
  const batch = writeBatch(db);
  batch.set(doc(db, 'globalMessages', id), { senderID: uid, text, createdAt: serverTimestamp() });
  batch.set(doc(db, 'globalChatSenders', uid), { messageID: id, lastSentAt: serverTimestamp() });
  return batch.commit();
}
test('global chat requires Google login, authentic authors, bounded reads and immutable messages', async () => {
  await create('alice', 'alice_initial');
  const db = google('alice');
  await assertSucceeds(globalSend(db, 'alice', 'first', 'Hello\nCapyFlow'));
  await assertSucceeds(getDocs(query(collection(google('bob'), 'globalMessages'), limit(50))));
  await assertFails(getDocs(collection(db, 'globalMessages')));
  await assertFails(getDocs(query(collection(db, 'globalMessages'), limit(51))));
  await assertFails(getDocs(query(collection(env.unauthenticatedContext().firestore(), 'globalMessages'), limit(50))));
  await assertFails(getDocs(query(collection(account('alice'), 'globalMessages'), limit(50))));
  await assertFails(globalSend(google('bob'), 'alice', 'spoofed'));
  await assertFails(updateDoc(doc(db, 'globalMessages', 'first'), { text: 'Changed' }));
  await assertFails(deleteDoc(doc(db, 'globalMessages', 'first')));
  await assertFails(getDoc(doc(google('bob'), 'globalChatSenders', 'alice')));
});
test('global chat validates messages and throttles atomic sends across devices', async () => {
  await create('alice', 'alice_initial');
  const db = google('alice');
  await assertFails(globalSend(db, 'alice', 'blank', ' \n '));
  await assertFails(globalSend(db, 'alice', 'long', 'x'.repeat(4001)));
  await assertFails(setDoc(doc(db, 'globalMessages', 'no_gate'), { senderID: 'alice', text: 'Hi', createdAt: serverTimestamp() }));
  await assertSucceeds(globalSend(db, 'alice', 'first'));
  await assertFails(globalSend(db, 'alice', 'rapid'));
  await env.withSecurityRulesDisabled(async c => { await updateDoc(doc(c.firestore(), 'globalChatSenders', 'alice'), { lastSentAt: Timestamp.fromMillis(Date.now() - 5000) }); });
  await assertSucceeds(globalSend(db, 'alice', 'second'));
});

test('simultaneous first messages preserve the committed thread and both authors', async () => {
  for (const [uid,peer] of [['alice','bob'],['bob','alice']]) await setDoc(doc(account(uid), 'follows', uid+'_'+peer), { followerID: uid, followingID: peer });
  async function first(uid, id) {
    const db = account(uid), ref = doc(db, 'conversations', 'alice_bob');
    return runTransaction(db, async tx => {
      const current = await tx.get(ref);
      if(!current.exists()) await tx.get(doc(db,'follows',uid+'_'+(uid==='alice'?'bob':'alice')));
      tx.set(doc(ref,'messages',id),{senderID:uid,text:id,createdAt:serverTimestamp()});
      const data={lastMessageID:id,lastText:id,lastSenderID:uid,updatedAt:serverTimestamp()};
      if(current.exists())tx.update(ref,{...data,['readMessageIDs.'+uid]:id});
      else tx.set(ref,{...data,createdAt:serverTimestamp(),memberIDs:['alice','bob'],readMessageIDs:{alice:uid==='alice'?id:'',bob:uid==='bob'?id:''}});
    });
  }
  await Promise.all([assertSucceeds(first('alice','one')),assertSucceeds(first('bob','two'))]);
  await assertSucceeds(getDoc(doc(account('alice'),'conversations','alice_bob','messages','one')));
  await assertSucceeds(getDoc(doc(account('bob'),'conversations','alice_bob','messages','two')));
  await assertFails(getDoc(doc(account('mallory'),'conversations','alice_bob')));
});

test('Global push opt-ins are private and only their owner can change or remove them',async()=>{
 const db=google('alice'),ref=doc(db,'globalPushDevices','installation');
 const data={uid:'alice',token:'private-token',platform:'android',updatedAt:serverTimestamp()};
 await assertSucceeds(setDoc(ref,data));
 await assertSucceeds(getDoc(ref));
 await assertFails(getDoc(doc(google('bob'),'globalPushDevices','installation')));
 await assertFails(setDoc(doc(google('bob'),'globalPushDevices','installation'),{...data,uid:'bob'}));
 await assertFails(getDocs(query(collection(db,'globalPushDevices'),limit(50))));
 await assertFails(setDoc(doc(account('password'),'globalPushDevices','other'),{...data,uid:'password'}));
 await assertSucceeds(deleteDoc(ref));
});
