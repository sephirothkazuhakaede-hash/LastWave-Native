import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { CacheStore } from '../src/cache-store.js';
import { createServer } from '../src/server.js';
import { TimingRecorder } from '../src/timings.js';

const audio = Buffer.alloc(24_000).map((_, index) => index % 251);

async function listen(server) {
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  return `http://127.0.0.1:${server.address().port}`;
}

async function close(server) {
  await new Promise((resolve) => server.close(resolve));
}

function upstreamServer() {
  return http.createServer((request, response) => {
    if (request.url === '/stale') {
      response.writeHead(403);
      response.end('expired');
      return;
    }
    const range = /^bytes=(\d+)-(\d*)$/u.exec(request.headers.range || '');
    if (range) {
      const start = Number(range[1]);
      const end = range[2] ? Math.min(Number(range[2]), audio.length - 1) : audio.length - 1;
      if (start >= audio.length || end < start) {
        response.writeHead(416, { 'Content-Range': `bytes */${audio.length}` });
        response.end();
        return;
      }
      const selected = audio.subarray(start, end + 1);
      response.writeHead(206, {
        'Content-Type': 'audio/mp4',
        'Accept-Ranges': 'bytes',
        'Content-Range': `bytes ${start}-${end}/${audio.length}`,
        'Content-Length': selected.length,
      });
      response.end(selected);
      return;
    }
    response.writeHead(200, {
      'Content-Type': 'audio/mp4', 'Accept-Ranges': 'bytes', 'Content-Length': audio.length,
    });
    response.end(audio);
  });
}

test('server proxies Range, refreshes a 403, and then serves its persistent cache', async (t) => {
  const upstream = upstreamServer();
  const upstreamRoot = await listen(upstream);
  t.after(() => close(upstream));

  const cacheRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'capyflow-server-test-'));
  t.after(() => fs.rm(cacheRoot, { recursive: true, force: true }));
  const cache = new CacheStore({
    root: cacheRoot, maxBytes: 10_000_000, maxAgeMs: 86_400_000, concurrency: 2,
  });
  await cache.init();
  t.after(() => cache.close());

  const invalidated = new Set();
  const resolveCounts = new Map();
  const downloadCounts = new Map();
  const formatInfo = quality => ({ container: 'm4a', codec: 'mp4a.40.2',
    bitrateKbps: quality === 'dataSaver' ? 48 : 128, sampleRateHz: 44100,
    formatId: quality === 'dataSaver' ? '139' : '140', selectedMode: quality });
  const resolver = {
    inFlightCount: 0,
    isInstalled: async () => true,
    resolve: async (videoId, quality, options = {}) => {
      resolveCounts.set(videoId, (resolveCounts.get(videoId) || 0) + 1);
      const stale = videoId === 'stale123xyz' && !options.force && !invalidated.has(videoId);
      return {
        videoId, quality, url: `${upstreamRoot}${stale ? '/stale' : '/audio'}`,
        headers: {}, title: 'Integration Song', artist: 'Test', duration: 96,
        contentLength: audio.length,
        mediaInfo: formatInfo(quality),
      };
    },
    invalidate: (videoId) => invalidated.add(videoId),
    download: async (videoId, quality, destination) => {
      downloadCounts.set(videoId, (downloadCounts.get(videoId) || 0) + 1);
      await fs.writeFile(destination, quality === 'dataSaver' ? Buffer.alloc(audio.length, 7) : audio);
      return { videoId, quality, duration: 96, mediaInfo: formatInfo(quality) };
    },
  };
  const config = {
    authMode: 'local', allowAnonymousLan: false, corsOrigin: '', host: '127.0.0.1',
  };
  const timings = new TimingRecorder(50);
  const logger = { info() {}, error() {} };
  const server = createServer({ config, resolver, cache, timings, logger, ytDlpVersion: 'test' });
  const root = await listen(server);
  t.after(() => close(server));

  const ranged = await fetch(`${root}/v1/audio/abc123xyz01?quality=high`, {
    headers: { Range: 'bytes=100-199' },
  });
  assert.equal(ranged.status, 206);
  assert.equal(ranged.headers.get('x-capyflow-cache'), 'MISS');
  assert.equal(JSON.parse(ranged.headers.get('x-capyflow-media-info')).bitrateKbps, 128);
  assert.equal(ranged.headers.get('content-range'), `bytes 100-199/${audio.length}`);
  assert.deepEqual(Buffer.from(await ranged.arrayBuffer()), audio.subarray(100, 200));

  const refreshed = await fetch(`${root}/v1/audio/stale123xyz?quality=automatic`, {
    headers: { Range: 'bytes=0-63' },
  });
  assert.equal(refreshed.status, 206);
  assert.deepEqual(Buffer.from(await refreshed.arrayBuffer()), audio.subarray(0, 64));
  assert.equal(resolveCounts.get('stale123xyz'), 2, '403 should cause one forced re-extraction');

  for (let attempt = 0; attempt < 50; attempt += 1) {
    if ((await cache.status('abc123xyz01', 'high')).cached) break;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  const cached = await fetch(`${root}/v1/download/abc123xyz01?quality=high`, {
    headers: { Range: 'bytes=-32' },
  });
  assert.equal(cached.status, 206);
  assert.equal(cached.headers.get('x-capyflow-cache'), 'HIT');
  assert.equal(JSON.parse(cached.headers.get('x-capyflow-media-info')).formatId, '140');
  assert.match(cached.headers.get('content-disposition'), /^attachment;/u);
  assert.deepEqual(Buffer.from(await cached.arrayBuffer()), audio.subarray(audio.length - 32));

  const [freshOne, freshTwo] = await Promise.all([
    fetch(`${root}/v1/download/fresh123xyz?quality=automatic`),
    fetch(`${root}/v1/download/fresh123xyz?quality=automatic`),
  ]);
  assert.equal(freshOne.status, 200);
  assert.equal(freshTwo.status, 200);
  assert.equal(freshOne.headers.get('x-capyflow-cache'), 'MISS');
  assert.equal(freshTwo.headers.get('x-capyflow-cache'), 'MISS');
  assert.match(freshOne.headers.get('server-timing'), /extract;desc="new extraction";dur=\d/);
  assert.deepEqual(Buffer.from(await freshOne.arrayBuffer()), audio);
  assert.deepEqual(Buffer.from(await freshTwo.arrayBuffer()), audio);
  assert.equal(downloadCounts.get('fresh123xyz'), 1, 'simultaneous downloads must share one MSI cache job');

  const freshHit = await fetch(`${root}/v1/download/fresh123xyz?quality=automatic`);
  assert.equal(freshHit.headers.get('x-capyflow-cache'), 'HIT');
  assert.equal(downloadCounts.get('fresh123xyz'), 1);
  await freshHit.arrayBuffer();

  const saverDownload = await fetch(`${root}/v1/download/fresh123xyz?quality=dataSaver`);
  assert.equal(JSON.parse(saverDownload.headers.get('x-capyflow-media-info')).bitrateKbps, 48);
  assert.deepEqual(Buffer.from(await saverDownload.arrayBuffer()), Buffer.alloc(audio.length, 7));
  const saverStream = await fetch(`${root}/v1/audio/fresh123xyz?quality=dataSaver`);
  assert.equal(saverStream.headers.get('x-capyflow-cache'), 'HIT');
  assert.deepEqual(Buffer.from(await saverStream.arrayBuffer()), Buffer.alloc(audio.length, 7));
  const saverResolve = await (await fetch(`${root}/v1/resolve/fresh123xyz?quality=dataSaver`)).json();
  assert.equal(saverResolve.quality, 'dataSaver');
  assert.equal(saverResolve.mediaInfo.bitrateKbps, 48);
  assert.equal(saverResolve.mediaInfo.sampleRateHz, 44100);
  const bestResolve = await (await fetch(`${root}/v1/resolve/fresh123xyz?quality=automatic`)).json();
  assert.equal(bestResolve.mediaInfo.bitrateKbps, 128);

  const health = await fetch(`${root}/health`);
  assert.equal(health.status, 200);
  assert.equal((await health.json()).status, 'ok');
});

test('server rejects multiple ranges without contacting the resolver', async (t) => {
  const rootDirectory = await fs.mkdtemp(path.join(os.tmpdir(), 'capyflow-range-server-test-'));
  t.after(() => fs.rm(rootDirectory, { recursive: true, force: true }));
  const cache = new CacheStore({ root: rootDirectory, maxBytes: 1_000_000, maxAgeMs: 100_000, concurrency: 1 });
  await cache.init();
  t.after(() => cache.close());
  let resolves = 0;
  const resolver = {
    inFlightCount: 0,
    isInstalled: async () => true,
    resolve: async () => { resolves += 1; throw new Error('should not resolve'); },
  };
  const server = createServer({
    config: { authMode: 'local', allowAnonymousLan: false, corsOrigin: '', host: '127.0.0.1' },
    resolver, cache, timings: new TimingRecorder(10), logger: { info() {}, error() {} },
  });
  const root = await listen(server);
  t.after(() => close(server));

  const response = await fetch(`${root}/v1/audio/abc123xyz01`, {
    headers: { Range: 'bytes=0-1,3-4' },
  });
  assert.equal(response.status, 416);
  assert.equal(resolves, 0);
});

test('lyrics endpoint shares v1 auth, returns standardized quality and caches without touching media', async (t) => {
  const { LyricsResolver } = await import('../src/lyrics.js');
  let queries = 0;
  const lyricsResolver = new LyricsResolver({ providers: [{ name: 'fixture', available: true, async search() {
    queries++; return [{ title: 'Song', artist: 'Singer', duration: 200, syncedLyrics: '[00:01]Fixture line' }];
  } }] });
  const config = { authMode: 'local', allowAnonymousLan: false, corsOrigin: '', host: '127.0.0.1' };
  const server = createServer({ config, resolver: {}, cache: {}, timings: new TimingRecorder(10),
    lyricsResolver, logger: { info() {}, error() {} } });
  const root = await listen(server); t.after(() => close(server));
  const url = root + '/v1/lyrics?title=Song&artist=Singer&duration=200';
  const first = await fetch(url); assert.equal(first.status, 200);
  const result = await first.json(); assert.equal(result.provider, 'fixture');
  assert.equal(result.synchronization, 'line'); assert.equal(result.timingOrigin, 'provider');
  assert.equal((await (await fetch(url)).json()).cached, true); assert.equal(queries, 1);
  assert.equal((await fetch(root + '/v1/lyrics?title=Song')).status, 400);
  const protectedServer = createServer({ config: { ...config, authMode: 'firebase' }, resolver: {}, cache: {},
    timings: new TimingRecorder(10), lyricsResolver, logger: { info() {}, error() {} } });
  const protectedRoot = await listen(protectedServer); t.after(() => close(protectedServer));
  assert.equal((await fetch(protectedRoot + '/v1/lyrics?title=Song&artist=Singer')).status, 401);
});
