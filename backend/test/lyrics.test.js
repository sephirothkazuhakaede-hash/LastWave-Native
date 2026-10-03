import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { LyricsResolver, rankCandidate, normalizeContent, defaultLyricsAdapters, LRCLIBAdapter, lyricRequest } from '../src/lyrics.js';
const request = { title: 'Song', artist: 'Singer', album: 'Album', duration: 200, videoId: 'abcdefghijk' };
const plain = { title: 'Song', artist: 'Singer', duration: 200, plainLyrics: 'Fixture line' };
const synced = { ...plain, syncedLyrics: '[00:01.25]Fixture line' };
const adapter = (name, candidates) => ({ name, available: true, async search() { return candidates; } });
test('queries all providers; synced fallback beats plain primary', async () => {
  const queried = [];
  const providers = ['lrclib', 'netease', 'qqmusic', 'kugou'].map((name, i) => ({ name, available: true,
    async search() { queried.push(name); return [i === 2 ? synced : plain]; } }));
  const result = await new LyricsResolver({ providers }).resolve(request);
  assert.equal(result.provider, 'qqmusic'); assert.equal(result.synchronization, 'line');
  assert.deepEqual(result.lines, [{ time: 1.25, text: 'Fixture line' }]); assert.equal(queried.length, 4);
});
test('rejects wrong variants, artist, duration, stable identity, explicit and instrumental mismatch', () => {
  for (const version of ['Live', 'Remix', 'Karaoke', 'Cover', 'Instrumental', 'Clean', 'Explicit', 'Nightcore', 'Sped Up', 'Slowed + Reverb', 'Acoustic']) {
    assert.equal(rankCandidate(request, { ...synced, title: `Song (${version})` }), null);
    assert.ok(rankCandidate({ ...request, title: `Song (${version})` }, { ...synced, title: `Song (${version})` }));
  }
  assert.equal(rankCandidate(request, { ...synced, artist: 'Singer Tribute' }), null);
  assert.equal(rankCandidate(request, { ...synced, duration: 250 }), null);
  assert.equal(rankCandidate(request, { ...synced, videoId: 'differentid' }), null);
  assert.equal(rankCandidate({ ...request, explicit: true }, { ...synced, explicit: false }), null);
  assert.equal(rankCandidate(request, { ...synced, instrumental: true }), null);
});
test('genuine words beat lines; estimated and invalid word timestamps earn no word rank', () => {
  const words = { ...plain, timingOrigin: 'provider', lines: [{ time: 1, text: 'Fixture line', words: [{ time: 1, text: 'Fixture' }, { time: 2, text: 'line' }] }] };
  assert.equal(normalizeContent(words).synchronization, 'word');
  assert.ok(rankCandidate(request, words).score > rankCandidate(request, synced).score);
  assert.equal(normalizeContent({ ...words, timingOrigin: 'estimated' }).synchronization, 'plain');
  assert.equal(normalizeContent({ ...words, lines: [{ time: 1, text: 'Fixture', words: [{ time: -1, text: 'Fixture' }] }] }).synchronization, 'plain');
  assert.equal(normalizeContent({ ...plain, syncedLyrics: 'Not LRC' }).synchronization, 'plain');
});
test('normalized match and album tie-break preserve track identity', () => {
  assert.ok(rankCandidate({ ...request, title: 'Sóng (Official Audio)' }, synced));
  assert.ok(rankCandidate(request, { ...synced, album: 'Album' }).score > rankCandidate(request, synced).score);
  assert.equal(rankCandidate(request, { ...synced, title: 'Other song' }), null);
  assert.ok(rankCandidate({ ...request, title: 'Song (feat. Guest)' }, synced));
  assert.equal(rankCandidate({ ...request, title: 'Song (feat. Guest)' }, { ...synced, title: 'Song (feat. Other)' }), null);
  assert.equal(rankCandidate(request, { ...synced, videoId: 'Abcdefghijk' }), null);
  assert.equal(rankCandidate(request, { ...synced, album: 'Album (Live)' }), null);
});
test('success cache persists, concurrent requests coalesce, TTL expires, variants separate', async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'capy-lyrics-')); let count = 0, now = 1000;
  const providers = [{ name: 'fixture', available: true, async search(q) { count++; return [{ ...synced, title: q.title }]; } }];
  try {
    const resolver = new LyricsResolver({ providers, root, now: () => now, ttlMs: 100 });
    await Promise.all([resolver.resolve(request), resolver.resolve(request)]); assert.equal(count, 1);
    assert.equal((await resolver.resolve(request)).cached, true);
    const reopened = new LyricsResolver({ providers, root, now: () => now, ttlMs: 100 });
    assert.equal((await reopened.resolve(request)).cached, true); assert.equal(count, 1);
    now += 101; await reopened.resolve(request); assert.equal(count, 2);
    await resolver.resolve({ ...request, title: 'Song (Live)' }); assert.equal(count, 3);
  } finally { await rm(root, { recursive: true, force: true }); }
});
test('isolates provider failures, never caches misses, documents unavailable providers', async () => {
  const failure = { name: 'down', available: true, async search() { throw new Error('network'); } };
  assert.equal((await new LyricsResolver({ providers: [failure, adapter('working', [synced])] }).resolve(request)).provider, 'working');
  const misses = new LyricsResolver({ providers: [adapter('empty', [])] });
  await assert.rejects(misses.resolve(request), { statusCode: 404 }); assert.equal(misses.memory.size, 0);
  await assert.rejects(new LyricsResolver({ providers: [failure] }).resolve(request), { statusCode: 503 });
  assert.deepEqual(defaultLyricsAdapters().filter(x => !x.available).map(x => x.name), ['netease', 'qqmusic', 'kugou']);
});
test('LRCLIB documented query maps metadata; malformed input is rejected', async () => {
  let queried;
  const provider = new LRCLIBAdapter(async url => { queried = url; return new Response(JSON.stringify([{ id: 1, trackName: 'Song', artistName: 'Singer', albumName: 'Album', syncedLyrics: '[00:01]Fixture', duration: 200 }])); });
  const candidates = await provider.search(request);
  assert.equal(queried.searchParams.get('track_name'), 'Song'); assert.equal(candidates[0].album, 'Album');
  assert.throws(() => lyricRequest({ title: 'Song' }), { statusCode: 400 });
  assert.throws(() => lyricRequest({ ...request, duration: 'NaN' }), { statusCode: 400 });
});
