import { readFile } from 'node:fs/promises';
import { HttpError } from './errors.js';

const bad = message => { throw new HttpError(400, 'invalid_admin_request', message); };
export function adminText(value, max, label) {
  if (typeof value !== 'string' || !value.trim() || value.trim().length > max) bad(`${label} must contain 1–${max} characters.`);
  return value.trim();
}
export function adminID(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/u.test(value)) bad('Invalid item ID.');
  return value;
}
export function announcementText(value) {
  const title = adminText(value.title, 80, 'Title'), body = adminText(value.body, 3500, 'Announcement');
  return { title, body, text: `📣 ${title}\n\n${body}` };
}
const iso = value => value?.toDate?.().toISOString() ?? null;

export class ControlAdmin {
  constructor(config, dependencies = null) { this.config = config; this.dependencies = dependencies; this.initializing = null; }
  async ready() {
    if (this.dependencies) return this.dependencies;
    if (!this.initializing) this.initializing = (async () => {
      if (!this.config.firebaseProjectId || !this.config.pushCredentials)
        throw new HttpError(503, 'admin_credentials_required', 'Connect the existing backend service-account file in local settings. It is never bundled into Control Center.');
      const json = JSON.parse(await readFile(this.config.pushCredentials, 'utf8'));
      if (json.type !== 'service_account' || json.project_id !== this.config.firebaseProjectId)
        throw new HttpError(503, 'admin_project_mismatch', 'The backend credentials belong to a different project.');
      const { initializeApp, cert, getApps } = await import('firebase-admin/app');
      const { getFirestore, FieldValue } = await import('firebase-admin/firestore');
      const { getAuth } = await import('firebase-admin/auth');
      const { getMessaging } = await import('firebase-admin/messaging');
      const app = getApps().find(app => app.name === 'capyflow-control-admin') ?? initializeApp({ credential: cert(json), projectId: json.project_id }, 'capyflow-control-admin');
      return { db: getFirestore(app), auth: getAuth(app), messaging: getMessaging(app), stamp: () => FieldValue.serverTimestamp() };
    })().catch(error => { this.initializing = null; throw error; });
    return this.initializing;
  }
  async actor(token) {
    const { auth } = await this.ready();
    const claims = await auth.verifyIdToken(token, true);
    if (!this.config.adminUIDs.includes(claims.uid)) throw new HttpError(403, 'admin_required', 'Administrator access required.');
    return claims.uid;
  }
  async audit(actor, action, target, detail = {}) {
    const { db, stamp } = await this.ready();
    await db.collection('controlCenterAudit').add({ actor, action, target, ...detail, createdAt: stamp() });
  }
  async users(query = '', page = '') {
    const { db, auth } = await this.ready();
    let records, nextPageToken = null;
    if (query.trim()) {
      query = adminText(query, 128, 'Search');
      try {
        if (query.includes('@') && !query.startsWith('@')) records = [await auth.getUserByEmail(query)];
        else if (query.startsWith('@')) {
          const profile = await db.collection('profiles').where('username', '==', query.slice(1).toLowerCase()).limit(1).get();
          records = profile.empty ? [] : [await auth.getUser(profile.docs[0].id)];
        } else records = [await auth.getUser(adminID(query))];
      } catch (error) { if (error.code === 'auth/user-not-found') records = []; else throw error; }
    } else {
      if (page.length > 1024) bad('Invalid next page.');
      const result = await auth.listUsers(30, page || undefined); records = result.users; nextPageToken = result.pageToken ?? null;
    }
    const profiles = records.length ? await db.getAll(...records.map(user => db.doc(`profiles/${user.uid}`))) : [];
    return { users: records.map((user, index) => ({ uid: user.uid, email: user.email ?? '', displayName: profiles[index]?.get('displayName') ?? user.displayName ?? '', username: profiles[index]?.get('username') ?? '', disabled: user.disabled, createdAt: user.metadata.creationTime, lastSignIn: user.metadata.lastSignInTime })), nextPageToken };
  }
  async setUser(actor, uid, patch) {
    adminID(uid);
    if (uid === actor || this.config.adminUIDs.includes(uid)) bad('Administrator accounts cannot be disabled from Control Center.');
    if (typeof patch.disabled !== 'boolean' || Object.keys(patch).some(key => key !== 'disabled')) bad('Only account enable/disable is supported.');
    const { auth } = await this.ready();
    await auth.updateUser(uid, { disabled: patch.disabled });
    if (patch.disabled) await auth.revokeRefreshTokens(uid);
    await this.audit(actor, patch.disabled ? 'user.disable' : 'user.enable', uid);
    return { uid, disabled: patch.disabled, note: 'Existing mobile sessions may remain valid until their current ID token expires (up to one hour).' };
  }
  async messages() {
    const { db } = await this.ready();
    const result = await db.collection('globalMessages').orderBy('createdAt', 'desc').limit(50).get();
    return { messages: result.docs.map(doc => ({ id: doc.id, senderID: doc.get('senderID'), text: doc.get('text'), createdAt: iso(doc.get('createdAt')) })) };
  }
  async moderate(actor, id, restore = false) {
    adminID(id); const { db, stamp } = await this.ready();
    const message = db.doc(`globalMessages/${id}`), backup = db.doc(`controlCenterModeration/${id}`);
    await db.runTransaction(async tx => {
      const [current, previous] = await Promise.all([tx.get(message), tx.get(backup)]);
      if (!current.exists) throw new HttpError(404, 'message_missing', 'Message no longer exists.');
      if (restore) {
        if (!previous.exists || !previous.get('redacted') || current.get('text') !== '[Message removed by moderator]') bad('This message cannot be restored.');
        tx.update(message, { text: previous.get('text') }); tx.update(backup, { redacted: false, updatedAt: stamp(), actor });
      } else {
        if (previous.get('redacted')) bad('This message is already hidden.');
        tx.set(backup, { text: current.get('text'), senderID: current.get('senderID'), redacted: true, actor, updatedAt: stamp() });
        tx.update(message, { text: '[Message removed by moderator]' });
      }
      tx.set(db.collection('controlCenterAudit').doc(), { actor, action: restore ? 'global.restore' : 'global.hide', target: id, createdAt: stamp() });
    });
    return { id, redacted: !restore };
  }
  async announcements() {
    const { db } = await this.ready();
    const result = await db.collection('controlCenterAnnouncements').orderBy('updatedAt', 'desc').limit(50).get();
    return { announcements: result.docs.map(doc => ({ id: doc.id, title: doc.get('title'), body: doc.get('body'), published: doc.get('published'), updatedAt: iso(doc.get('updatedAt')) })) };
  }
  async saveAnnouncement(actor, id, value) {
    adminID(id); const content = announcementText(value);
    if (typeof value.published !== 'boolean') bad('Choose draft or published.');
    const { db, stamp } = await this.ready();
    const ref = db.doc(`controlCenterAnnouncements/${id}`), message = db.doc(`globalMessages/announcement-${id}`);
    await db.runTransaction(async tx => {
      const [old, priorMessage] = await Promise.all([tx.get(ref), tx.get(message)]);
      tx.set(ref, { title: content.title, body: content.body, published: value.published, actor, updatedAt: stamp() });
      if (value.published) {
        if (priorMessage.exists) tx.update(message, { text: content.text });
        else tx.set(message, { senderID: actor, text: content.text, createdAt: stamp() });
      } else if (old.get('published') && priorMessage.exists) tx.update(message, { text: '[Announcement withdrawn]' });
      tx.set(db.collection('controlCenterAudit').doc(), { actor, action: value.published ? 'announcement.publish' : 'announcement.draft', target: id, createdAt: stamp() });
    });
    return { id, published: value.published };
  }
  async pushRecipients() {
    const { db } = await this.ready(); const result = [], seen = new Set(); let cursor;
    do {
      let query = db.collection('globalPushDevices').orderBy('__name__').limit(500);
      if (cursor) query = query.startAfter(cursor);
      const page = await query.get();
      for (const doc of page.docs) {
        const data = doc.data();
        if (data.platform === 'android' && typeof data.uid === 'string' && typeof data.token === 'string' && data.token && !seen.has(data.token)) { seen.add(data.token); result.push(data); }
      }
      if (result.length > 5000) bad('This sender supports up to 5,000 opted-in Android devices.');
      cursor = page.size === 500 ? page.docs.at(-1) : null;
    } while (cursor);
    return result;
  }
  async pushPreview() { return { androidDevices: (await this.pushRecipients()).length, audience: 'Android users who enabled Global Chat push notifications', iosSupported: false }; }
  async sendPush(actor, value) {
    const id = adminID(value.id), title = adminText(value.title, 120, 'Notification title'), body = adminText(value.body, 300, 'Notification text');
    const { db, messaging, stamp } = await this.ready();
    const existing = await db.doc(`controlCenterPush/${id}`).get();
    if (existing.exists) {
      if (existing.get('actor') !== actor || existing.get('title') !== title || existing.get('body') !== body) bad('This notification ID is already reserved.');
      if (existing.get('status') === 'complete') return { id, success: existing.get('success'), failed: existing.get('failed'), alreadySent: true };
      throw new HttpError(409, 'push_already_requested', 'This notification is sending or was interrupted. Do not retry it with a new ID until its delivery status is checked.');
    }
    const recipients = (await this.pushRecipients()).filter(device => device.uid !== actor);
    const ref = db.doc(`controlCenterPush/${id}`);
    await db.runTransaction(async tx => { if ((await tx.get(ref)).exists) throw new HttpError(409, 'push_already_requested', 'This notification was already requested. Refresh its status before retrying.'); tx.set(ref, { actor, title, body, status: 'sending', createdAt: stamp(), recipients: recipients.length }); });
    let success = 0, failed = 0;
    try {
      for (let i = 0; i < recipients.length; i += 500) {
        const batch = recipients.slice(i, i + 500).map(device => ({ token: device.token, data: { kind: 'global', recipientID: device.uid, senderID: actor, messageID: `admin-${id}`, title, body }, android: { priority: 'high', ttl: 120000, collapseKey: 'global-chat' } }));
        const outcome = await messaging.sendEach(batch); success += outcome.successCount; failed += outcome.failureCount;
      }
      await ref.update({ status: 'complete', success, failed, updatedAt: stamp() });
      await this.audit(actor, 'push.send', id, { success, failed });
      return { id, success, failed };
    } catch (error) { await ref.update({ status: 'interrupted', success, failed, updatedAt: stamp() }); throw error; }
  }
  async history() {
    const { db } = await this.ready();
    const result = await db.collection('controlCenterAudit').orderBy('createdAt', 'desc').limit(50).get();
    return { events: result.docs.map(doc => ({ id: doc.id, actor: doc.get('actor'), action: doc.get('action'), target: doc.get('target'), createdAt: iso(doc.get('createdAt')) })) };
  }
}
