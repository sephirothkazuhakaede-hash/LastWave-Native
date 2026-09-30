import assert from 'node:assert/strict';
import test from 'node:test';
import { YtDlpClient } from '../src/yt-dlp.js';

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
