import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { CacheStore } from '../src/cache-store.js';

async function temporaryDirectory(t) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'capyflow-cache-test-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  return directory;
}

test('CacheStore deduplicates producers and reloads completed entries', async (t) => {
  const root = await temporaryDirectory(t);
  const options = { root, maxBytes: 10_000_000, maxAgeMs: 86_400_000, concurrency: 2 };
  const cache = new CacheStore(options);
  await cache.init();
  t.after(() => cache.close());

  let producerCalls = 0;
  const producer = async (destination) => {
    producerCalls += 1;
    await new Promise((resolve) => setTimeout(resolve, 20));
    await fs.writeFile(destination, Buffer.alloc(20_000, 7));
    return { duration: 123, mediaInfo: { codec: 'mp4a.40.2', bitrateKbps: 128, formatId: '140' } };
  };

  const [first, second] = await Promise.all([
    cache.ensure('abc123xyz01', 'automatic', producer, { title: 'Test song', duration: 123 }),
    cache.ensure('abc123xyz01', 'automatic', producer, { title: 'Test song', duration: 123 }),
  ]);
  assert.equal(producerCalls, 1);
  assert.equal(first.audioPath, second.audioPath);
  assert.equal(first.size, 20_000);

  cache.close();
  const reloaded = new CacheStore(options);
  await reloaded.init();
  t.after(() => reloaded.close());
  const hit = await reloaded.get('abc123xyz01', 'automatic');
  assert.equal(hit.title, 'Test song');
  assert.equal(hit.duration, 123);
  assert.equal(hit.size, 20_000);
  assert.equal(hit.mediaInfo.codec, 'mp4a.40.2');
  assert.equal(hit.mediaInfo.bitrateKbps, 128);
  assert.equal(hit.mediaInfo.formatId, '140');
});

test('CacheStore separates data-saver and high-quality files', async (t) => {
  const root = await temporaryDirectory(t);
  const cache = new CacheStore({ root, maxBytes: 10_000_000, maxAgeMs: 86_400_000, concurrency: 1 });
  await cache.init();
  t.after(() => cache.close());

  const producer = (byte) => async (destination) => fs.writeFile(destination, Buffer.alloc(20_000, byte));
  await cache.ensure('abc123xyz01', 'high', producer(1));
  await cache.ensure('abc123xyz01', 'dataSaver', producer(2));
  const high = await cache.get('abc123xyz01', 'high');
  const low = await cache.get('abc123xyz01', 'dataSaver');
  assert.notEqual(high.audioPath, low.audioPath);
  assert.equal((await fs.readFile(high.audioPath))[0], 1);
  assert.equal((await fs.readFile(low.audioPath))[0], 2);
});
