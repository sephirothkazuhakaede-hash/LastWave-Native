import fs from 'node:fs/promises';
import { performance } from 'node:perf_hooks';
import { HttpError, ProcessError } from './errors.js';
import { runProcess } from './process-runner.js';
import { elapsedMilliseconds } from './timings.js';

export const supportedQualities = new Set(['automatic', 'high', 'dataSaver']);

const formatSelectors = Object.freeze({
  automatic: 'bestaudio[ext=m4a][acodec^=mp4a]/bestaudio[ext=m4a]',
  high: 'bestaudio[ext=m4a][acodec^=mp4a]/bestaudio[ext=m4a]',
  dataSaver: 'worstaudio[ext=m4a][acodec^=mp4a]/worstaudio[ext=m4a]',
});

export function normalizeQuality(value) {
  if (value === undefined || value === null || value === '') return 'automatic';
  const text = String(value);
  if (!supportedQualities.has(text)) {
    throw new HttpError(400, 'invalid_quality', 'quality must be automatic, high, or dataSaver.');
  }
  return text;
}

export function validateVideoId(value) {
  const id = String(value ?? '');
  if (!/^[A-Za-z0-9_-]{6,20}$/u.test(id)) {
    throw new HttpError(400, 'invalid_video_id', 'The video ID is invalid.');
  }
  return id;
}

function videoUrl(videoId) {
  return `https://www.youtube.com/watch?v=${encodeURIComponent(videoId)}`;
}

function safeHeaders(input) {
  const result = {};
  const blocked = new Set(['host', 'content-length', 'connection', 'transfer-encoding']);
  for (const [name, value] of Object.entries(input ?? {})) {
    const normalizedName = String(name).toLowerCase();
    if (blocked.has(normalizedName) || typeof value !== 'string' || /[\r\n]/u.test(value)) continue;
    result[normalizedName] = value;
  }
  return result;
}

function selectedDownload(json) {
  const requested = Array.isArray(json.requested_downloads) ? json.requested_downloads[0] : null;
  return requested && typeof requested === 'object' ? requested : json;
}

export function mediaInfo(json, quality) {
  const selected = selectedDownload(json);
  const positive = value => Number.isFinite(Number(value)) && Number(value) > 0 ? Number(value) : null;
  const formats = (json.formats ?? []).filter(format => format.ext === 'm4a'
    && format.vcodec === 'none' && String(format.acodec).startsWith('mp4a'));
  const choices = new Set(formats.map(format => positive(format.abr)).filter(Boolean));
  return {
    container: cleanText(selected.ext, 16) || null,
    codec: cleanText(selected.acodec, 64) || null,
    bitrateKbps: positive(selected.abr),
    sampleRateHz: positive(selected.asr),
    formatId: cleanText(selected.format_id, 64) || null,
    selectedMode: quality,
    effectiveMode: choices.size === 1 ? 'automatic' : quality,
    availableQualityCount: choices.size || null,
  };
}

function cleanText(value, maximum = 500) {
  return typeof value === 'string' ? value.replace(/[\u0000-\u001f\u007f]/gu, '').slice(0, maximum) : '';
}

function extractorFailureMessage(stderr) {
  const text = String(stderr || '').toLowerCase();
  if (text.includes('private video')) return 'This YouTube upload is private.';
  if (text.includes('members-only') || text.includes('members only')) return 'This upload is only available to channel members.';
  if (text.includes('age-restricted') || text.includes('age restricted')) return 'This upload is age-restricted and needs an authenticated YouTube session.';
  if (text.includes('not available in your country') || text.includes('not available in your region')) return 'This upload is not available from the server region.';
  if (text.includes('sign in to confirm') || text.includes('not a bot')) return 'YouTube temporarily blocked this server route as automated traffic.';
  if (text.includes('video unavailable') || text.includes('has been removed')) return 'This YouTube upload is unavailable or was removed.';
  if (text.includes('requested format is not available')) return 'This upload has no iPhone-compatible M4A audio stream.';
  return 'The audio source could not be resolved.';
}

export class YtDlpClient {
  #binaryPath;
  #baseArgs;
  #resolveTimeoutMs;
  #downloadTimeoutMs;
  #cacheTtlMs;
  #runner;
  #timings;
  #resolved = new Map();
  #inFlight = new Map();

  constructor({
    binaryPath,
    baseArgs = [],
    resolveTimeoutMs = 45_000,
    downloadTimeoutMs = 900_000,
    cacheTtlMs = 900_000,
    runner = runProcess,
    timings,
  }) {
    this.#binaryPath = binaryPath;
    this.#baseArgs = [...baseArgs];
    this.#resolveTimeoutMs = resolveTimeoutMs;
    this.#downloadTimeoutMs = downloadTimeoutMs;
    this.#cacheTtlMs = cacheTtlMs;
    this.#runner = runner;
    this.#timings = timings;
  }

  get inFlightCount() {
    return this.#inFlight.size;
  }

  async version() {
    try {
      const result = await this.#runner(this.#binaryPath, [...this.#baseArgs, '--version'], { timeoutMs: 10_000 });
      return result.stdout.trim().split(/\r?\n/u)[0] || 'unknown';
    } catch {
      return null;
    }
  }

  async isInstalled() {
    try {
      await fs.access(this.#binaryPath);
      return true;
    } catch {
      return false;
    }
  }

  invalidate(videoId, quality = 'automatic') {
    this.#resolved.delete(`${videoId}:${quality}`);
  }

  async resolve(videoId, quality = 'automatic', { force = false } = {}) {
    const id = validateVideoId(videoId);
    const normalizedQuality = normalizeQuality(quality);
    const key = `${id}:${normalizedQuality}`;
    if (!force) {
      const cached = this.#resolved.get(key);
      if (cached && cached.usableUntil > Date.now()) return { ...cached.value, resolution: 'memory-cache' };
      const active = this.#inFlight.get(key);
      if (active) return active;
    }

    const job = this.#resolveFresh(id, normalizedQuality);
    this.#inFlight.set(key, job);
    try {
      const value = await job;
      this.#resolved.set(key, { value, usableUntil: this.#usableUntil(value.url) });
      return value;
    } finally {
      if (this.#inFlight.get(key) === job) this.#inFlight.delete(key);
    }
  }

  async #resolveFresh(videoId, quality) {
    const startedAt = performance.now();
    let ok = false;
    const timingDetails = { quality };
    try {
      const args = [
        ...this.#baseArgs,
        '--no-playlist',
        '--no-warnings',
        '--no-progress',
        '--socket-timeout', '15',
        '--retries', '3',
        '--fragment-retries', '3',
        '--extractor-retries', '3',
        '--format', formatSelectors[quality],
        '--dump-single-json',
        '--skip-download',
        videoUrl(videoId),
      ];
      const result = await this.#runner(this.#binaryPath, args, { timeoutMs: this.#resolveTimeoutMs });
      let json;
      try {
        json = JSON.parse(result.stdout);
      } catch (error) {
        throw new ProcessError('yt-dlp returned invalid JSON.', { stderr: result.stderr, cause: error });
      }
      const selected = selectedDownload(json);
      if (typeof selected.url !== 'string' || !selected.url.startsWith('http')) {
        throw new ProcessError('yt-dlp did not return a usable m4a stream URL.', { stderr: result.stderr });
      }
      timingDetails.container = cleanText(selected.ext || json.ext, 16) || 'm4a';
      timingDetails.codec = cleanText(selected.acodec || json.acodec, 64) || 'unknown';
      ok = true;
      return {
        videoId,
        quality,
        url: selected.url,
        headers: safeHeaders(selected.http_headers ?? json.http_headers),
        title: cleanText(json.title),
        artist: cleanText(json.artist || json.uploader || json.channel),
        duration: Number.isFinite(Number(json.duration)) ? Number(json.duration) : null,
        contentLength: Number.isSafeInteger(Number(selected.filesize || selected.filesize_approx))
          ? Number(selected.filesize || selected.filesize_approx)
          : null,
        ext: cleanText(selected.ext || json.ext, 16) || 'm4a',
        acodec: cleanText(selected.acodec || json.acodec, 64),
        mediaInfo: mediaInfo(json, quality),
        resolution: 'fresh',
      };
    } catch (error) {
      if (error instanceof ProcessError) {
        throw new HttpError(502, 'extractor_failed', extractorFailureMessage(error.stderr), { cause: error });
      }
      throw error;
    } finally {
      this.#timings?.record('extract', elapsedMilliseconds(startedAt), ok, timingDetails);
    }
  }

  async download(videoId, quality, destinationPath) {
    const id = validateVideoId(videoId);
    const normalizedQuality = normalizeQuality(quality);
    const startedAt = performance.now();
    let ok = false;
    try {
      const args = [
        ...this.#baseArgs,
        '--no-playlist',
        '--no-warnings',
        '--no-progress',
        '--no-part',
        '--no-mtime',
        '--force-overwrites',
        '--socket-timeout', '15',
        '--retries', '5',
        '--fragment-retries', '5',
        '--extractor-retries', '3',
        '--format', formatSelectors[normalizedQuality],
        '--print', 'after_move:%()j',
        '--output', destinationPath,
        videoUrl(id),
      ];
      const result = await this.#runner(this.#binaryPath, args, { timeoutMs: this.#downloadTimeoutMs });
      const stat = await fs.stat(destinationPath);
      if (!stat.isFile() || stat.size < 16_384) {
        throw new ProcessError('yt-dlp produced an incomplete audio file.');
      }
      ok = true;
      let downloadedInfo = null;
      try { downloadedInfo = mediaInfo(JSON.parse(result.stdout.trim().split(/\r?\n/u).at(-1)), normalizedQuality); }
      catch { /* Older extractors may not report metadata. Never invent it. */ }
      return { videoId: id, quality: normalizedQuality, size: stat.size, mediaInfo: downloadedInfo };
    } catch (error) {
      if (error instanceof ProcessError) {
        throw new HttpError(502, 'download_failed', extractorFailureMessage(error.stderr), { cause: error });
      }
      throw error;
    } finally {
      this.#timings?.record('cache-download', elapsedMilliseconds(startedAt), ok, { quality: normalizedQuality });
    }
  }

  #usableUntil(url) {
    try {
      const expiry = Number(new URL(url).searchParams.get('expire')) * 1000;
      if (Number.isFinite(expiry) && expiry > Date.now()) return Math.max(Date.now(), expiry - 300_000);
    } catch {
      // Fall through to a deliberately short in-memory lifetime.
    }
    return Date.now() + this.#cacheTtlMs;
  }
}
