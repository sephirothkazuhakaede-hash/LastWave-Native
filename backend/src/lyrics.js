import { createHash, randomUUID } from 'node:crypto';
import { mkdir, readFile, writeFile, rename, readdir, unlink } from 'node:fs/promises';
import path from 'node:path';
import { HttpError } from './errors.js';

export const normalize = value => String(value ?? '').normalize('NFKD').replace(/\p{M}/gu, '')
  .toLowerCase().replace(/\b(official (music )?video|official audio|lyrics? video|audio only)\b/gu, '')
  .replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
const variants = [
  ['live', /\blive\b/u], ['remix', /\b(remix|mix)\b/u], ['karaoke', /\bkaraoke\b/u],
  ['cover', /\bcover\b/u], ['instrumental', /\binstrumental\b/u], ['clean', /\b(clean|radio edit)\b/u],
  ['explicit', /\bexplicit\b/u], ['nightcore', /\bnightcore\b/u],
  ['sped', /\b(sped up|speed up)\b/u], ['slowed', /\b(slowed|reverb)\b/u],
  ['acoustic', /\bacoustic\b/u], ['edit', /\b(edit|extended)\b/u], ['remaster', /\b(remaster|remastered)\b/u],
];
const titleKey = value => normalize(String(value ?? '').replace(/\s*[([]\s*(?:feat\.?|featuring|ft\.?)\s+[^)\]]*[)\]]/giu, '').replace(/\s+\b(?:feat\.?|featuring|ft\.?)\s+.*$/giu, ''));
const versionSet = value => variants.filter(([, re]) => re.test(normalize(value))).map(([name]) => name).join('|');
export function lyricRequest(input) {
  const result = {};
  for (const name of ['title', 'artist', 'album', 'videoId', 'isrc', 'recordingId']) {
    result[name] = String(input[name] ?? '').trim();
    if (result[name].length > 300) throw new HttpError(400, 'invalid_lyrics_query', `${name} is too long.`);
  }
  if (!result.title || !result.artist) throw new HttpError(400, 'invalid_lyrics_query', 'Title and artist are required.');
  result.duration = input.duration == null || input.duration === '' ? null : Number(input.duration);
  if (result.duration != null && (!Number.isFinite(result.duration) || result.duration <= 0 || result.duration > 86400)) {
    throw new HttpError(400, 'invalid_lyrics_query', 'Duration must be a positive number of seconds.');
  }
  if (input.explicit != null && input.explicit !== '') {
    if (![true, false, 'true', 'false'].includes(input.explicit)) throw new HttpError(400, 'invalid_lyrics_query', 'Explicit must be true or false.');
    result.explicit = input.explicit === true || input.explicit === 'true';
  }
  return result;
}

// Only source-provided timestamps are accepted. No interpolation or estimation.
export function parseLRC(source) {
  const lines = [];
  const offset = Number(/\[offset:([+-]?\d+)\]/iu.exec(source)?.[1] ?? 0) / 1000;
  for (const raw of String(source ?? '').split(/\r?\n/u)) {
    const stamps = [...raw.matchAll(/\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]/gu)];
    const text = raw.replace(/\[[^\]]*\]/gu, '').trim();
    for (const stamp of stamps) if (text && Number(stamp[2]) < 60) {
      lines.push({ time: Math.max(0, Number(stamp[1]) * 60 + Number(stamp[2]) + Number(`0.${stamp[3] ?? 0}`) + offset), text });
    }
  }
  return lines.sort((a, b) => a.time - b.time);
}

export function normalizeContent(candidate) {
  const plain = String(candidate.plainLyrics ?? '').trim();
  // Future authorized adapters may supply genuine word/syllable timing arrays.
  // A claim of "word" without valid source timestamps never earns that rank.
  const supplied = candidate.lines;
  if (candidate.timingOrigin === 'provider' && Array.isArray(supplied) && supplied.length &&
      supplied.every(line => Number.isFinite(line.time) && line.time >= 0 && typeof line.text === 'string' && line.text.trim() &&
        Array.isArray(line.words) && line.words.length && line.words.every(word =>
          Number.isFinite(word.time) && word.time >= line.time && typeof word.text === 'string' && word.text.trim()))) {
    const ordered = supplied.every((line, i) => (!i || line.time >= supplied[i - 1].time) &&
      line.words.every((word, j) => !j || word.time >= line.words[j - 1].time));
    if (ordered) return { synchronization: candidate.synchronization === 'syllable' ? 'syllable' : 'word', timingOrigin: 'provider', lines: supplied };
  }
  const lines = parseLRC(candidate.syncedLyrics ?? '');
  if (lines.length) return { synchronization: 'line', timingOrigin: 'provider', lines };
  if (plain) return { synchronization: 'plain', timingOrigin: 'none', lines: plain.split(/\r?\n/u).filter(x => x.trim()).map(text => ({ time: null, text })) };
  return null;
}

export function rankCandidate(request, candidate) {
  if (!candidate.title || !candidate.artist) return null;
  if (versionSet(request.title) !== versionSet(candidate.title)) return null;
  if (request.album && candidate.album && versionSet(request.album) !== versionSet(candidate.album)) return null;
  if (titleKey(request.title) !== titleKey(candidate.title) || normalize(request.artist) !== normalize(candidate.artist)) return null;
  const credit = value => /\b(?:feat\.?|featuring|ft\.?)\s+([^\)\]]+)/iu.exec(String(value ?? ''))?.[1];
  const wantedCredit = credit(request.title), foundCredit = credit(candidate.title);
  if (wantedCredit && foundCredit && normalize(wantedCredit) !== normalize(foundCredit)) return null;
  for (const key of ['videoId', 'isrc', 'recordingId']) {
    if (request[key] && candidate[key] && (key === 'isrc' ? request[key].toUpperCase() !== candidate[key].toUpperCase() : request[key] !== candidate[key])) return null;
  }
  if (typeof request.explicit === 'boolean' && typeof candidate.explicit === 'boolean' && request.explicit !== candidate.explicit) return null;
  const actual = Number(candidate.duration);
  const hasDuration = candidate.duration != null && Number.isFinite(actual) && actual > 0;
  const distance = request.duration != null && hasDuration ? Math.abs(request.duration - actual) : 0;
  if (request.duration != null && hasDuration && distance > Math.max(5, Math.min(12, request.duration * 0.04))) return null;
  if (candidate.instrumental && !/\binstrumental\b/u.test(normalize(request.title))) return null;
  const content = normalizeContent(candidate);
  if (!content) return null;
  const quality = { plain: 0, line: 100, word: 200, syllable: 200 }[content.synchronization];
  const identity = ['videoId', 'isrc', 'recordingId'].filter(key => request[key] && request[key] === candidate[key]).length * 5;
  const album = request.album && normalize(request.album) === normalize(candidate.album) ? 4 : 0;
  return { candidate, content, score: quality + identity + album + (hasDuration ? 2 : 0) - distance / 10 };
}

export class LRCLIBAdapter {
  name = 'lrclib';
  available = true;
  constructor(fetchImpl = globalThis.fetch) { this.fetchImpl = fetchImpl; }
  async search(request) {
    const url = new URL('https://lrclib.net/api/search');
    url.searchParams.set('track_name', request.title);
    url.searchParams.set('artist_name', request.artist);
    const response = await this.fetchImpl(url, { signal: AbortSignal.timeout(8000), headers: {
      'User-Agent': 'CapyFlow/0.4.5 (https://github.com/sephirothkazuhakaede-hash/LastWave-Native)',
    } });
    if (!response.ok) throw new Error(`LRCLIB returned ${response.status}`);
    const text = await response.text();
    if (text.length > 2_000_000) throw new Error('Lyrics response too large');
    const records = JSON.parse(text);
    if (!Array.isArray(records)) throw new Error('Invalid lyrics response');
    return records.slice(0, 100).map(record => ({ ...record, provider: this.name, providerID: String(record.id),
      title: record.trackName, artist: record.artistName, album: record.albumName }));
  }
}
export class UnavailableLyricsAdapter {
  available = false;
  constructor(name, reason) { this.name = name; this.reason = reason; }
  async search() { return []; }
}
export function defaultLyricsAdapters(fetchImpl) {
  return [new LRCLIBAdapter(fetchImpl), ...['netease', 'qqmusic', 'kugou'].map(name =>
    new UnavailableLyricsAdapter(name, 'No authorized, documented lyrics search interface was validated. Adapter disabled; no scraping or impersonation.'))];
}

export class LyricsResolver {
  constructor({ providers = defaultLyricsAdapters(), root = null, ttlMs = 7 * 86400000, now = Date.now, maxEntries = 2000 } = {}) {
    Object.assign(this, { providers, root, ttlMs, now, maxEntries });
    this.memory = new Map(); this.pending = new Map();
  }
  async resolve(input) {
    const request = lyricRequest(input);
    const key = createHash('sha256').update(JSON.stringify({ ...request, title: normalize(request.title), artist: normalize(request.artist), album: normalize(request.album) })).digest('hex');
    let saved = this.memory.get(key);
    if (!saved && this.root) {
      try { saved = JSON.parse(await readFile(path.join(this.root, key + '.json'), 'utf8')); } catch { /* cold cache */ }
    }
    if (saved?.schemaVersion === 1 && saved.expiresAt > this.now() && saved.result?.lines?.length) return { ...saved.result, cached: true };
    if (this.pending.has(key)) return this.pending.get(key);
    if (this.pending.size >= 32) throw new HttpError(503, 'lyrics_busy', 'Lyrics resolver is busy. Try again shortly.');
    const task = this.lookup(request, key);
    this.pending.set(key, task);
    try { return await task; } finally { this.pending.delete(key); }
  }
  async lookup(request, key) {
    const available = this.providers.filter(p => p.available);
    const attempts = await Promise.allSettled(available.map(p => p.search(request)));
    const candidates = attempts.flatMap((attempt, i) => attempt.status === 'fulfilled' && Array.isArray(attempt.value)
      ? attempt.value.map(c => ({ ...c, provider: available[i].name })) : []);
    const ranked = candidates.map(c => rankCandidate(request, c)).filter(Boolean)
      .sort((a, b) => b.score - a.score || String(a.candidate.provider).localeCompare(String(b.candidate.provider)));
    if (!ranked.length) {
      const failed = attempts.length && attempts.every(a => a.status === 'rejected');
      throw new HttpError(failed ? 503 : 404, failed ? 'lyrics_providers_unavailable' : 'lyrics_not_found', 'No matching lyrics are currently available.');
    }
    const { candidate, content } = ranked[0];
    const result = { schemaVersion: 1, provider: candidate.provider, providerID: candidate.providerID ?? null,
      ...content, track: { title: candidate.title, artist: candidate.artist, album: candidate.album ?? null, duration: candidate.duration ?? null },
      providers: this.providers.map(p => ({ name: p.name, available: p.available, reason: p.reason ?? null })), cached: false };
    const entry = { schemaVersion: 1, expiresAt: this.now() + this.ttlMs, result };
    this.memory.set(key, entry);
    while (this.memory.size > this.maxEntries) this.memory.delete(this.memory.keys().next().value);
    if (this.root) {
      try {
        await mkdir(this.root, { recursive: true });
        const file = path.join(this.root, key + '.json'), temp = file + '.' + randomUUID() + '.tmp';
        await writeFile(temp, JSON.stringify(entry)); await rename(temp, file);
        // Bound persistent cache without putting cache errors on the critical path.
        const files = (await readdir(this.root)).filter(f => /^[a-f0-9]{64}\.json$/u.test(f));
        if (files.length > this.maxEntries) for (const old of files.slice(0, files.length - this.maxEntries)) if (old !== key + '.json') await unlink(path.join(this.root, old));
      } catch { /* a read-only disk must not prevent lyrics */ }
    }
    return result;
  }
}
