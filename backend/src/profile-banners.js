import fs from 'node:fs/promises';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { HttpError } from './errors.js';

export const MAX_GIF_BYTES = 5 * 1024 * 1024;
const validID = value => typeof value === 'string' && /^[a-z0-9][a-z0-9_-]{0,63}$/u.test(value) && value !== 'none';
const fail = message => { throw new HttpError(400, 'invalid_banner', message); };

// Parse the entire container before accepting it; a GIF filename/header alone is insufficient.
export function inspectGIF(data) {
  if (!Buffer.isBuffer(data) || data.length > MAX_GIF_BYTES || data.length < 14 ||
      !['GIF87a', 'GIF89a'].includes(data.toString('ascii', 0, 6))) fail('Choose a GIF of up to 5 MB.');
  const width = data.readUInt16LE(6), height = data.readUInt16LE(8);
  if (!width || !height || width > 2048 || height > 2048) fail('GIF dimensions must be at most 2048 × 2048.');
  let at = 13, frames = 0;
  const take = size => { at += size; if (at > data.length) fail('The GIF is incomplete.'); };
  const blocks = () => { while (true) { if (at >= data.length) fail('The GIF is incomplete.'); const size = data[at++]; if (!size) return; take(size); } };
  if (data[10] & 128) take(3 * (2 ** ((data[10] & 7) + 1)));
  while (at < data.length) {
    const type = data[at++];
    if (type === 0x3b) {
      if (at !== data.length || frames < 2) fail('Choose an animated GIF with at least two frames.');
      return { width, height, frames, byteSize: data.length };
    }
    if (type === 0x21) { take(1); blocks(); continue; }
    if (type !== 0x2c || at + 9 > data.length) fail('The GIF contains invalid image data.');
    const left = data.readUInt16LE(at), top = data.readUInt16LE(at + 2);
    const w = data.readUInt16LE(at + 4), h = data.readUInt16LE(at + 6), packed = data[at + 8];
    if (!w || !h || left + w > width || top + h > height) fail('GIF frame dimensions are invalid.');
    take(9); if (packed & 128) take(3 * (2 ** ((packed & 7) + 1)));
    if (at >= data.length || data[at] < 2 || data[at] > 8) fail('GIF compression is invalid.');
    take(1); blocks(); frames++;
    if (frames > 300 || frames * width * height > 200_000_000) fail('This GIF is too complex. Use fewer or smaller frames.');
  }
  fail('The GIF is incomplete.');
}

export async function readBody(request, maximum) {
  let size = 0; const chunks = [];
  for await (const chunk of request) {
    size += chunk.length;
    if (size > maximum) throw new HttpError(413, 'banner_too_large', 'The upload exceeds the size limit.');
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

export class ProfileBannerStore {
  constructor(root) { this.root = root; this.queue = Promise.resolve(); }
  async init() { await fs.mkdir(this.root, { recursive: true }); }
  async seedDefault(data) {
    if (await this.get('capy-parade-v1')) return;
    await this.upload('capy-parade-v1', 'Capy parade', data);
    await this.update('capy-parade-v1', { published: true }, async () => {});
  }
  async list(admin = false) {
    await this.init();
    const names = (await fs.readdir(this.root)).filter(name => name.endsWith('.json'));
    const entries = await Promise.all(names.map(async name => JSON.parse(await fs.readFile(path.join(this.root, name), 'utf8'))));
    return entries.filter(item => !item.deleted && (admin || item.published)).sort((a, b) => a.name.localeCompare(b.name));
  }
  async get(id) {
    if (!validID(id)) fail('Use a lowercase banner ID with letters, numbers, underscores or dashes.');
    try { return JSON.parse(await fs.readFile(path.join(this.root, `${id}.json`), 'utf8')); }
    catch (error) { if (error.code === 'ENOENT') return null; throw error; }
  }
  serial(operation) {
    const task = this.queue.then(operation); this.queue = task.catch(() => {}); return task;
  }
  async write(item) {
    const temporary = path.join(this.root, `${randomUUID()}.tmp`);
    await fs.writeFile(temporary, JSON.stringify(item), { flag: 'wx' });
    await fs.rename(temporary, path.join(this.root, `${item.id}.json`));
  }
  upload(id, name, data) {
    return this.serial(async () => {
      await this.init(); if (!validID(id)) fail('Invalid banner ID.');
      if (typeof name !== 'string' || !name.trim() || name.length > 60) fail('Add a name of up to 60 characters.');
      if (await this.get(id)) throw new HttpError(409, 'banner_exists', 'This ID is already reserved. Use a new ID.');
      if ((await this.list(true)).length >= 100) fail('The library limit is 100 banners.');
      const metadata = inspectGIF(data), revision = createHash('sha256').update(data).digest('hex');
      await fs.writeFile(path.join(this.root, `${id}-${revision}.gif`), data, { flag: 'wx' });
      const item = { id, name: name.trim(), revision, ...metadata, published: false, deleted: false,
        path: `/v1/profile-banners/${id}/${revision}.gif`, updatedAt: new Date().toISOString() };
      await this.write(item); return item;
    });
  }
  update(id, patch, mirror) {
    return this.serial(async () => {
      const item = await this.get(id);
      if (!item || item.deleted) throw new HttpError(404, 'banner_not_found', 'Banner not found.');
      if (Object.keys(patch).some(key => !['name', 'published', 'deleted'].includes(key))) fail('Unsupported banner field.');
      if ('name' in patch && (typeof patch.name !== 'string' || !patch.name.trim() || patch.name.length > 60)) fail('Invalid banner name.');
      if (['published', 'deleted'].some(key => key in patch && typeof patch[key] !== 'boolean')) fail('Invalid publication state.');
      const next = { ...item, ...patch, updatedAt: new Date().toISOString() };
      if (next.deleted) next.published = false;
      // Revoke the selectable-ID mirror before hiding/removing. Existing profile IDs remain safe.
      await mirror(next.id, next.published);
      await this.write(next);
      if (next.deleted) await fs.rm(path.join(this.root, `${item.id}-${item.revision}.gif`), { force: true });
      return next;
    });
  }
  async file(id, revision, admin) {
    const item = await this.get(id);
    if (!item || item.deleted || (!admin && !item.published) || item.revision !== revision) {
      throw new HttpError(404, 'banner_not_found', 'Banner not found.');
    }
    return fs.readFile(path.join(this.root, `${id}-${revision}.gif`));
  }
}

export async function authorizeBannerAdmin(request, config, verifier) {
  const match = /^Bearer\s+([^\s]+)$/iu.exec(request.headers.authorization || '');
  if (!match || !verifier) throw new HttpError(401, 'admin_sign_in_required', 'Sign in to Control Center.');
  const claims = await verifier.verify(match[1]);
  if (!(config.adminUIDs || []).includes(claims.sub)) throw new HttpError(403, 'admin_required', 'This account is not a CapyFlow administrator.');
  return match[1];
}

export async function mirrorBannerPermission(id, published, token, config, fetchImpl) {
  const project = config.firebaseProjectId;
  if (!project) throw new HttpError(503, 'admin_setup_required', 'Set FIREBASE_PROJECT_ID before publishing banners.');
  const response = await fetchImpl(`https://firestore.googleapis.com/v1/projects/${encodeURIComponent(project)}/databases/(default)/documents/profileBannerPermissions/${id}`, {
    method: 'PATCH', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ fields: { published: { booleanValue: published } } }), signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) throw new HttpError(503, 'banner_permission_sync_failed', 'Could not sync banner selection permissions. Deploy the catalog rules and retry.');
}
