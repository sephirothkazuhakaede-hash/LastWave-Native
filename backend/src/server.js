import http from 'node:http';
import { randomUUID } from 'node:crypto';
import { performance } from 'node:perf_hooks';
import { authorizeRequest } from './firebase-auth.js';
import { HttpError } from './errors.js';
import { proxyAudio, serveCachedFile } from './media.js';
import { elapsedMilliseconds } from './timings.js';
import { normalizeQuality, validateVideoId } from './yt-dlp.js';

function json(response, statusCode, value, extraHeaders = {}) {
  const body = Buffer.from(`${JSON.stringify(value)}\n`);
  response.writeHead(statusCode, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': String(body.length),
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    ...extraHeaders,
  });
  response.end(body);
}

function routeMatch(pathname, operation) {
  const expression = new RegExp(`^/v1/${operation}/([A-Za-z0-9_-]{6,20})$`, 'u');
  return expression.exec(pathname);
}

function applyCors(request, response, config) {
  if (!config.corsOrigin) return;
  if (request.headers.origin === config.corsOrigin) {
    response.setHeader('Access-Control-Allow-Origin', config.corsOrigin);
    response.setHeader('Vary', 'Origin');
    response.setHeader('Access-Control-Allow-Headers', 'Authorization, Range, Content-Type');
    response.setHeader('Access-Control-Allow-Methods', 'GET, HEAD, POST, OPTIONS');
    response.setHeader('Access-Control-Expose-Headers',
      'Accept-Ranges, Content-Length, Content-Range, Server-Timing, X-CapyFlow-Cache, X-CapyFlow-Duration, X-CapyFlow-Audio-Quality');
  }
}

export function createServer({
  config,
  resolver,
  cache,
  tokenVerifier = null,
  timings,
  ytDlpVersion = null,
  fetchImpl = globalThis.fetch,
  logger = console,
}) {
  const startedAt = Date.now();

  const server = http.createServer(async (request, response) => {
    const requestStarted = performance.now();
    const requestId = randomUUID();
    response.setHeader('X-Request-ID', requestId);
    applyCors(request, response, config);

    let pathname = '/';
    try {
      const url = new URL(request.url || '/', `http://${request.headers.host || 'localhost'}`);
      pathname = url.pathname;

      if (request.method === 'OPTIONS' && config.corsOrigin) {
        response.writeHead(204);
        response.end();
        return;
      }

      if (request.method === 'GET' && pathname === '/') {
        json(response, 200, {
          service: 'CapyFlow media backend',
          health: '/health',
          api: '/v1/audio/{videoID}?quality=automatic',
        });
        return;
      }

      if (request.method === 'GET' && pathname === '/health') {
        const installed = await resolver.isInstalled();
        json(response, installed ? 200 : 503, {
          status: installed ? 'ok' : 'degraded',
          uptimeSeconds: Math.floor((Date.now() - startedAt) / 1000),
          ytDlp: { installed, version: ytDlpVersion },
          cache: await cache.stats(),
          resolver: { inFlight: resolver.inFlightCount },
          authMode: config.authMode,
          listening: config.host,
          now: new Date().toISOString(),
        });
        return;
      }

      if (!pathname.startsWith('/v1/')) {
        throw new HttpError(404, 'not_found', 'Route not found.');
      }
      const identity = await authorizeRequest(request, config, tokenVerifier);

      if (request.method === 'GET' && pathname === '/v1/diagnostics/timings') {
        json(response, 200, {
          timings: timings.snapshot(),
          cache: await cache.stats(),
          resolver: { inFlight: resolver.inFlightCount },
        });
        return;
      }

      const audio = routeMatch(pathname, 'audio');
      const download = routeMatch(pathname, 'download');
      if ((request.method === 'GET' || request.method === 'HEAD') && (audio || download)) {
        const videoId = validateVideoId((audio || download)[1]);
        const quality = normalizeQuality(url.searchParams.get('quality'));
        const entry = await cache.get(videoId, quality);
        if (entry) {
          await serveCachedFile(request, response, entry, { attachment: Boolean(download), timings });
        } else if (download) {
          // Offline downloads should be deterministic: finish (or join) the
          // MSI's single cache job, then transfer that verified local file.
          // Streaming stays progressive through /audio, while /download no
          // longer starts a second upstream transfer beside cache creation.
          const cachedEntry = await cache.ensure(
            videoId,
            quality,
            (temporaryPath) => resolver.download(videoId, quality, temporaryPath),
          );
          await serveCachedFile(request, response, cachedEntry, { attachment: true, timings });
        } else {
          await proxyAudio(request, response, {
            videoId,
            quality,
            resolver,
            cache,
            fetchImpl,
            attachment: Boolean(download),
            timings,
          });
        }
        return;
      }

      const resolveMatch = routeMatch(pathname, 'resolve');
      if (request.method === 'GET' && resolveMatch) {
        const videoId = validateVideoId(resolveMatch[1]);
        const quality = normalizeQuality(url.searchParams.get('quality'));
        const resolveStarted = performance.now();
        const entry = await cache.get(videoId, quality);
        let metadata;
        if (entry) {
          metadata = entry;
        } else {
          metadata = await resolver.resolve(videoId, quality);
          cache.schedule(
            videoId,
            quality,
            (temporaryPath) => resolver.download(videoId, quality, temporaryPath),
            metadata,
          );
        }
        const resolveMs = elapsedMilliseconds(resolveStarted);
        json(response, 200, {
          videoId,
          quality,
          title: metadata.title || '',
          artist: metadata.artist || '',
          duration: metadata.duration ?? null,
          contentLength: entry?.size ?? metadata.contentLength ?? null,
          cached: Boolean(entry),
          caching: !entry && cache.hasActiveJob(videoId, quality),
          audioPath: `/v1/audio/${videoId}?quality=${quality}`,
          downloadPath: `/v1/download/${videoId}?quality=${quality}`,
        }, { 'Server-Timing': `resolve;dur=${resolveMs}` });
        return;
      }

      const cacheMatch = routeMatch(pathname, 'cache');
      if (request.method === 'GET' && cacheMatch) {
        const videoId = validateVideoId(cacheMatch[1]);
        const quality = normalizeQuality(url.searchParams.get('quality'));
        json(response, 200, { videoId, quality, ...await cache.status(videoId, quality) });
        return;
      }
      if (request.method === 'POST' && cacheMatch) {
        const videoId = validateVideoId(cacheMatch[1]);
        const quality = normalizeQuality(url.searchParams.get('quality'));
        const existing = await cache.get(videoId, quality);
        if (!existing) {
          cache.schedule(videoId, quality, (temporaryPath) => resolver.download(videoId, quality, temporaryPath));
        }
        json(response, existing ? 200 : 202, {
          videoId,
          quality,
          cached: Boolean(existing),
          caching: !existing,
        });
        return;
      }

      throw new HttpError(404, 'not_found', 'Route not found.');
    } catch (error) {
      const statusCode = error instanceof HttpError ? error.statusCode : 500;
      const code = error instanceof HttpError ? error.code : 'internal_error';
      const message = error instanceof HttpError ? error.message : 'The backend could not complete the request.';
      if (!response.headersSent) {
        if (statusCode === 401) response.setHeader('WWW-Authenticate', 'Bearer realm="CapyFlow"');
        json(response, statusCode, { error: { code, message, requestId } });
      } else {
        response.destroy();
      }
      logger.error?.(JSON.stringify({
        level: 'error', requestId, method: request.method, path: pathname,
        status: statusCode, code, message: error.message,
      }));
    } finally {
      const durationMs = elapsedMilliseconds(requestStarted);
      timings.record('http-request', durationMs, response.statusCode < 500, {
        method: request.method || '', status: response.statusCode || 0,
      });
      logger.info?.(JSON.stringify({
        level: 'info', requestId, method: request.method, path: pathname,
        status: response.statusCode, durationMs,
      }));
    }
  });

  server.requestTimeout = 0;
  server.headersTimeout = 60_000;
  server.keepAliveTimeout = 10_000;
  server.maxHeadersCount = 100;
  return server;
}
