import fs from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { JobQueue } from './job-queue.js';
import { normalizeQuality, validateVideoId } from './yt-dlp.js';

function entryKey(videoId, quality) {
  return `${validateVideoId(videoId)}.${normalizeQuality(quality)}`;
}

function publicMetadata(metadata) {
  return {
    videoId: metadata.videoId,
    quality: metadata.quality,
    title: typeof metadata.title === 'string' ? metadata.title.slice(0, 500) : '',
    artist: typeof metadata.artist === 'string' ? metadata.artist.slice(0, 500) : '',
    duration: Number.isFinite(metadata.duration) ? metadata.duration : null,
    size: Number.isSafeInteger(metadata.size) ? metadata.size : null,
    createdAt: metadata.createdAt,
    accessedAt: metadata.accessedAt,
  };
}

export class CacheStore {
  #root;
  #maxBytes;
  #maxAgeMs;
  #queue;
  #entries = new Map();
  #jobs = new Map();
  #pruneTimer = null;

  constructor({ root, maxBytes, maxAgeMs, concurrency = 2 }) {
    this.#root = root;
    this.#maxBytes = maxBytes;
    this.#maxAgeMs = maxAgeMs;
    this.#queue = new JobQueue(concurrency);
  }

  get jobs() {
    return { ...this.#queue.stats, deduplicatedKeys: this.#jobs.size };
  }

  async init() {
    await fs.mkdir(this.#root, { recursive: true });
    const files = await fs.readdir(this.#root, { withFileTypes: true });
    await Promise.all(files
      .filter((entry) => entry.isFile() && (entry.name.includes('.tmp.') || entry.name.endsWith('.tmp')))
      .map((entry) => fs.rm(path.join(this.#root, entry.name), { force: true }).catch(() => {})));

    const metadataFiles = files.filter((entry) => entry.isFile() && entry.name.endsWith('.json'));
    for (const file of metadataFiles) {
      try {
        const metadataPath = path.join(this.#root, file.name);
        const metadata = JSON.parse(await fs.readFile(metadataPath, 'utf8'));
        const key = entryKey(metadata.videoId, metadata.quality);
        const audioPath = this.#audioPath(key);
        const stat = await fs.stat(audioPath);
        if (!stat.isFile() || stat.size < 16_384) throw new Error('invalid cache entry');
        this.#entries.set(key, {
          ...publicMetadata({ ...metadata, size: stat.size }),
          key,
          audioPath,
          metadataPath,
        });
      } catch {
        await fs.rm(path.join(this.#root, file.name), { force: true }).catch(() => {});
      }
    }

    await this.prune();
    this.#pruneTimer = setInterval(() => this.prune().catch(() => {}), 60 * 60 * 1000);
    this.#pruneTimer.unref?.();
  }

  close() {
    if (this.#pruneTimer) clearInterval(this.#pruneTimer);
    this.#pruneTimer = null;
  }

  async get(videoId, quality = 'automatic') {
    const key = entryKey(videoId, quality);
    const entry = this.#entries.get(key);
    if (!entry) return null;
    try {
      const stat = await fs.stat(entry.audioPath);
      if (!stat.isFile() || stat.size < 16_384) throw new Error('missing audio');
      const previousAccess = Date.parse(entry.accessedAt || 0);
      entry.size = stat.size;
      entry.accessedAt = new Date().toISOString();
      if (!Number.isFinite(previousAccess) || Date.now() - previousAccess > 60_000) {
        this.#writeMetadata(entry).catch(() => {});
      }
      return { ...entry };
    } catch {
      this.#entries.delete(key);
      await this.#removeFiles(key);
      return null;
    }
  }

  hasActiveJob(videoId, quality = 'automatic') {
    return this.#jobs.has(entryKey(videoId, quality));
  }

  ensure(videoId, quality, producer, seedMetadata = {}) {
    const key = entryKey(videoId, quality);
    const existing = this.#jobs.get(key);
    if (existing) return existing;

    const job = (async () => {
      const hit = await this.get(videoId, quality);
      if (hit) return hit;
      return this.#queue.enqueue(() => this.#produce(key, videoId, quality, producer, seedMetadata));
    })();
    this.#jobs.set(key, job);
    job.finally(() => {
      if (this.#jobs.get(key) === job) this.#jobs.delete(key);
    }).catch(() => {});
    return job;
  }

  schedule(videoId, quality, producer, seedMetadata = {}) {
    const job = this.ensure(videoId, quality, producer, seedMetadata);
    job.catch(() => {});
    return job;
  }

  async #produce(key, videoId, quality, producer, seedMetadata) {
    const secondCheck = await this.get(videoId, quality);
    if (secondCheck) return secondCheck;

    const temporaryPath = path.join(this.#root, `${key}.tmp.${randomUUID()}.m4a`);
    try {
      const produced = await producer(temporaryPath);
      const stat = await fs.stat(temporaryPath);
      if (!stat.isFile() || stat.size < 16_384) throw new Error('The cache producer wrote an incomplete file.');

      const audioPath = this.#audioPath(key);
      await fs.rm(audioPath, { force: true });
      await fs.rename(temporaryPath, audioPath);
      const timestamp = new Date().toISOString();
      const entry = {
        key,
        audioPath,
        metadataPath: this.#metadataPath(key),
        videoId,
        quality,
        title: seedMetadata.title || produced?.title || '',
        artist: seedMetadata.artist || produced?.artist || '',
        duration: seedMetadata.duration ?? produced?.duration ?? null,
        size: stat.size,
        createdAt: timestamp,
        accessedAt: timestamp,
      };
      this.#entries.set(key, entry);
      await this.#writeMetadata(entry);
      this.prune().catch(() => {});
      return { ...entry };
    } catch (error) {
      await fs.rm(temporaryPath, { force: true }).catch(() => {});
      throw error;
    }
  }

  async status(videoId, quality = 'automatic') {
    const entry = await this.get(videoId, quality);
    return {
      cached: Boolean(entry),
      caching: this.hasActiveJob(videoId, quality),
      metadata: entry ? publicMetadata(entry) : null,
    };
  }

  async stats() {
    let totalBytes = 0;
    for (const entry of this.#entries.values()) totalBytes += Number(entry.size) || 0;
    return {
      entries: this.#entries.size,
      totalBytes,
      maxBytes: this.#maxBytes,
      jobs: this.jobs,
    };
  }

  async prune() {
    const now = Date.now();
    const entries = [...this.#entries.values()];
    let totalBytes = entries.reduce((sum, entry) => sum + (Number(entry.size) || 0), 0);
    entries.sort((left, right) => Date.parse(left.accessedAt || 0) - Date.parse(right.accessedAt || 0));

    for (const entry of entries) {
      const expired = now - Date.parse(entry.accessedAt || entry.createdAt || 0) > this.#maxAgeMs;
      if (!expired && totalBytes <= this.#maxBytes) continue;
      if (this.#jobs.has(entry.key)) continue;
      this.#entries.delete(entry.key);
      totalBytes -= Number(entry.size) || 0;
      await this.#removeFiles(entry.key);
    }
  }

  #audioPath(key) {
    return path.join(this.#root, `${key}.m4a`);
  }

  #metadataPath(key) {
    return path.join(this.#root, `${key}.json`);
  }

  async #removeFiles(key) {
    await Promise.all([
      fs.rm(this.#audioPath(key), { force: true }).catch(() => {}),
      fs.rm(this.#metadataPath(key), { force: true }).catch(() => {}),
    ]);
  }

  async #writeMetadata(entry) {
    const destination = this.#metadataPath(entry.key);
    const temporary = `${destination}.tmp.${randomUUID()}`;
    await fs.writeFile(temporary, `${JSON.stringify(publicMetadata(entry), null, 2)}\n`, 'utf8');
    await fs.rm(destination, { force: true });
    await fs.rename(temporary, destination);
  }
}
