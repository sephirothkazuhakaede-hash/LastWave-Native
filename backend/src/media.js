import fs from 'node:fs';
import { pipeline } from 'node:stream/promises';
import { Readable, Transform } from 'node:stream';
import { performance } from 'node:perf_hooks';
import { HttpError } from './errors.js';
import { parseByteRange } from './range.js';
import { elapsedMilliseconds } from './timings.js';

function setCommonHeaders(response, { cacheState, quality, duration, serverTiming }) {
  response.setHeader('Accept-Ranges', 'bytes');
  response.setHeader('Content-Type', 'audio/mp4');
  response.setHeader('Cache-Control', 'private, no-store');
  response.setHeader('X-Content-Type-Options', 'nosniff');
  response.setHeader('X-CapyFlow-Cache', cacheState);
  response.setHeader('X-CapyFlow-Audio-Quality', quality);
  if (Number.isFinite(duration) && duration >= 0) response.setHeader('X-CapyFlow-Duration', String(duration));
  if (serverTiming) response.setHeader('Server-Timing', serverTiming);
}

function attachmentHeader(title, videoId) {
  const fallbackBase = String(title || videoId)
    .normalize('NFKD')
    .replace(/[^A-Za-z0-9._ -]/gu, '')
    .trim()
    .slice(0, 80) || videoId;
  const fallback = `${fallbackBase.replace(/["\\]/gu, '_')}.m4a`;
  const encoded = encodeURIComponent(`${String(title || videoId).slice(0, 120)}.m4a`)
    .replace(/['()]/gu, escape)
    .replace(/\*/gu, '%2A');
  return `attachment; filename="${fallback}"; filename*=UTF-8''${encoded}`;
}

function validateRemoteRange(value) {
  if (!value) return null;
  if (!/^bytes=(?:\d+-\d*|-\d+)$/u.test(value)) {
    throw new HttpError(416, 'invalid_range', 'Only one byte range is supported.');
  }
  return value;
}

export async function serveCachedFile(request, response, entry, { attachment = false, timings } = {}) {
  const transferStarted = performance.now();
  const range = parseByteRange(request.headers.range, entry.size);
  const timing = 'cache;desc="hit";dur=0';
  setCommonHeaders(response, {
    cacheState: 'HIT',
    quality: entry.quality,
    duration: entry.duration,
    serverTiming: timing,
  });
  if (attachment) response.setHeader('Content-Disposition', attachmentHeader(entry.title, entry.videoId));

  if (range?.unsatisfiable) {
    response.writeHead(416, { 'Content-Range': `bytes */${entry.size}` });
    response.end();
    return;
  }

  const start = range?.start ?? 0;
  const end = range?.end ?? entry.size - 1;
  const length = range?.length ?? entry.size;
  const status = range ? 206 : 200;
  const headers = { 'Content-Length': String(length) };
  if (range) headers['Content-Range'] = `bytes ${start}-${end}/${entry.size}`;
  response.writeHead(status, headers);
  if (request.method === 'HEAD') {
    response.end();
    timings?.record('transfer-total', elapsedMilliseconds(transferStarted), true, { source: 'cache', bytes: 0 });
    return;
  }
  let bytes = 0;
  let firstByte = true;
  const meter = new Transform({
    transform(chunk, encoding, callback) {
      bytes += chunk.length;
      if (firstByte) {
        firstByte = false;
        timings?.record('first-client-byte', elapsedMilliseconds(transferStarted), true, { source: 'cache' });
      }
      callback(null, chunk);
    },
  });
  try {
    await pipeline(fs.createReadStream(entry.audioPath, { start, end }), meter, response);
    timings?.record('transfer-total', elapsedMilliseconds(transferStarted), true, { source: 'cache', bytes });
  } catch (error) {
    const clientClosed = request.aborted || response.destroyed || error?.code === 'ERR_STREAM_PREMATURE_CLOSE';
    timings?.record('transfer-total', elapsedMilliseconds(transferStarted), clientClosed, {
      source: 'cache', bytes, clientClosed,
    });
    if (!clientClosed) throw error;
  }
}

function upstreamHeaders(resolved, range) {
  const headers = new Headers();
  for (const [name, value] of Object.entries(resolved.headers ?? {})) headers.set(name, value);
  if (range) headers.set('range', range);
  headers.set('accept', '*/*');
  return headers;
}

function copyUpstreamHeaders(upstream, response) {
  for (const name of ['content-length', 'content-range', 'etag', 'last-modified']) {
    const value = upstream.headers.get(name);
    if (value) response.setHeader(name, value);
  }
}

export async function proxyAudio(request, response, {
  videoId,
  quality,
  resolver,
  cache,
  fetchImpl = globalThis.fetch,
  attachment = false,
  timings,
}) {
  const transferStarted = performance.now();
  const requestRange = validateRemoteRange(request.headers.range);
  const resolveStarted = performance.now();
  let resolved = await resolver.resolve(videoId, quality);
  const resolveMs = elapsedMilliseconds(resolveStarted);
  let upstream;
  let upstreamMs = 0;

  for (let attempt = 0; attempt < 2; attempt += 1) {
    const upstreamStarted = performance.now();
    const abortController = new AbortController();
    const abort = () => abortController.abort();
    request.once('aborted', abort);
    try {
      upstream = await fetchImpl(resolved.url, {
        method: 'GET',
        headers: upstreamHeaders(resolved, requestRange),
        redirect: 'follow',
        signal: abortController.signal,
      });
    } finally {
      request.removeListener('aborted', abort);
      upstreamMs += elapsedMilliseconds(upstreamStarted);
    }
    if (upstream.status !== 403 || attempt === 1) break;
    await upstream.body?.cancel().catch(() => {});
    resolver.invalidate(videoId, quality);
    const refreshStarted = performance.now();
    resolved = await resolver.resolve(videoId, quality, { force: true });
    upstreamMs += elapsedMilliseconds(refreshStarted);
  }

  if (upstream.status === 416) {
    setCommonHeaders(response, {
      cacheState: 'MISS', quality, duration: resolved.duration,
      serverTiming: `resolve;dur=${resolveMs}, upstream;dur=${upstreamMs}`,
    });
    const contentRange = upstream.headers.get('content-range');
    if (contentRange) response.setHeader('Content-Range', contentRange);
    response.writeHead(416);
    response.end();
    await upstream.body?.cancel().catch(() => {});
    return;
  }
  if (![200, 206].includes(upstream.status) || !upstream.body) {
    await upstream.body?.cancel().catch(() => {});
    timings?.record('proxy-upstream', upstreamMs, false, { status: upstream.status, quality });
    throw new HttpError(502, 'upstream_failed', 'The audio source rejected the stream request.');
  }

  setCommonHeaders(response, {
    cacheState: 'MISS',
    quality,
    duration: resolved.duration,
    serverTiming: `resolve;dur=${resolveMs}, upstream;dur=${upstreamMs}`,
  });
  copyUpstreamHeaders(upstream, response);
  if (attachment) response.setHeader('Content-Disposition', attachmentHeader(resolved.title, videoId));
  response.writeHead(upstream.status);

  cache.schedule(
    videoId,
    quality,
    (temporaryPath) => resolver.download(videoId, quality, temporaryPath),
    resolved,
  );

  timings?.record('proxy-upstream', upstreamMs, true, { status: upstream.status, quality });
  if (request.method === 'HEAD') {
    response.end();
    await upstream.body.cancel().catch(() => {});
    return;
  }

  const nodeStream = Readable.fromWeb(upstream.body);
  let bytes = 0;
  let firstByte = true;
  const meter = new Transform({
    transform(chunk, encoding, callback) {
      bytes += chunk.length;
      if (firstByte) {
        firstByte = false;
        const firstByteMs = elapsedMilliseconds(transferStarted);
        timings?.record('first-source-byte', firstByteMs, true, {
          source: 'upstream', quality, codec: resolved.acodec || 'unknown', container: resolved.ext || 'm4a',
        });
        timings?.record('first-client-byte', firstByteMs, true, { source: 'upstream', quality });
      }
      callback(null, chunk);
    },
  });
  const abortUpstream = () => {
    if (!response.writableEnded) nodeStream.destroy();
  };
  request.once('aborted', abortUpstream);
  try {
    await pipeline(nodeStream, meter, response);
    timings?.record('transfer-total', elapsedMilliseconds(transferStarted), true, { source: 'upstream', quality, bytes });
  } catch (error) {
    const clientClosed = request.aborted || response.destroyed || error?.code === 'ERR_STREAM_PREMATURE_CLOSE';
    timings?.record('transfer-total', elapsedMilliseconds(transferStarted), clientClosed, {
      source: 'upstream', quality, bytes, clientClosed,
    });
    if (!clientClosed) throw error;
  } finally {
    request.removeListener('aborted', abortUpstream);
  }
}
