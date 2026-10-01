import assert from 'node:assert/strict';
import test from 'node:test';
import { YtDlpClient, mediaInfo } from '../src/yt-dlp.js';

test('quality chooses different original M4A formats and reports actual metadata', async () => {
  const formats = [48, 128].map(abr => ({
    format_id: String(abr), ext: 'm4a', acodec: 'mp4a.40.2', vcodec: 'none', abr, asr: 44100,
    url: `https://media.example/${abr}.m4a`,
  }));
  const selectors = [];
  const client = new YtDlpClient({ binaryPath: 'fake', runner: async (_, args) => {
    const selector = args[args.indexOf('--format') + 1];
    selectors.push(selector);
    assert.equal(args.includes('--audio-quality'), false);
    assert.equal(args.includes('--extract-audio'), false);
    const selected = selector.startsWith('worst') ? formats[0] : formats[1];
    return { stdout: JSON.stringify({ formats, requested_downloads: [selected] }) };
  }});
  const low = await client.resolve('abc123xyz01', 'dataSaver');
  const best = await client.resolve('abc123xyz01', 'automatic');
  assert.notEqual(selectors[0], selectors[1]);
  assert.notEqual(low.url, best.url);
  assert.equal(low.mediaInfo.bitrateKbps, 48);
  assert.equal(best.mediaInfo.bitrateKbps, 128);
  assert.equal(best.mediaInfo.sampleRateHz, 44100);
  assert.equal(best.mediaInfo.availableQualityCount, 2);
  console.log('Quality selection: Data Saver = original AAC 48 kbps; Best Available = original AAC 128 kbps');
});

test('a single available source quality is honestly reported as Best Available', () => {
  const format = { ext: 'm4a', acodec: 'mp4a.40.2', vcodec: 'none', abr: 128 };
  const info = mediaInfo({ ...format, formats: [format] }, 'dataSaver');
  assert.equal(info.selectedMode, 'dataSaver');
  assert.equal(info.effectiveMode, 'automatic');
  assert.equal(info.availableQualityCount, 1);
  assert.equal(info.sampleRateHz, null);
});

test('YtDlpClient deduplicates concurrent extraction and keeps upstream headers private', async () => {
  let calls = 0;
  const runner = async () => {
    calls += 1;
    await new Promise((resolve) => setTimeout(resolve, 20));
    return {
      stdout: JSON.stringify({
        id: 'abc123xyz01',
        title: 'Song',
        uploader: 'Artist',
        duration: 180,
        url: 'https://media.example/audio.m4a?expire=4102444800',
        ext: 'm4a',
        acodec: 'mp4a.40.2',
        http_headers: {
          'User-Agent': 'test-agent',
          Host: 'should-not-forward.example',
          Connection: 'close',
        },
      }),
      stderr: '',
      exitCode: 0,
    };
  };
  const client = new YtDlpClient({ binaryPath: 'fake', runner });
  const [first, second] = await Promise.all([
    client.resolve('abc123xyz01', 'high'),
    client.resolve('abc123xyz01', 'high'),
  ]);
  assert.equal(calls, 1);
  assert.equal(first.url, second.url);
  assert.equal(first.headers['user-agent'], 'test-agent');
  assert.equal(first.headers.host, undefined);
  assert.equal(first.headers.connection, undefined);

  const cached = await client.resolve('abc123xyz01', 'high');
  assert.equal(calls, 1);
  assert.equal(cached.resolution, 'memory-cache');
});
