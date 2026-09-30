import { performance } from 'node:perf_hooks';

const root = (process.env.CAPYFLOW_BACKEND_URL || 'http://127.0.0.1:8787').replace(/\/+$/u, '');
const ids = process.argv.slice(2);
if (ids.length === 0) {
  console.error('Usage: npm run benchmark -- VIDEO_ID [VIDEO_ID ...]');
  process.exit(2);
}

for (const videoId of ids) {
  const url = `${root}/v1/audio/${encodeURIComponent(videoId)}?quality=automatic`;
  const started = performance.now();
  try {
    const response = await fetch(url, { headers: { Range: 'bytes=0-65535' } });
    const headersMs = performance.now() - started;
    const reader = response.body?.getReader();
    const first = reader ? await reader.read() : { value: new Uint8Array(), done: true };
    const firstByteMs = performance.now() - started;
    await reader?.cancel();
    const errorText = response.ok ? null : Buffer.from(first.value || []).toString('utf8').slice(0, 500);
    console.log(JSON.stringify({
      videoId,
      status: response.status,
      headersMs: Math.round(headersMs * 10) / 10,
      firstByteMs: Math.round(firstByteMs * 10) / 10,
      firstChunkBytes: first.value?.byteLength || 0,
      cache: response.headers.get('x-capyflow-cache'),
      serverTiming: response.headers.get('server-timing'),
      contentRange: response.headers.get('content-range'),
      error: errorText,
    }));
  } catch (error) {
    console.log(JSON.stringify({
      videoId,
      status: 0,
      elapsedMs: Math.round((performance.now() - started) * 10) / 10,
      error: error.message,
    }));
  }
}
