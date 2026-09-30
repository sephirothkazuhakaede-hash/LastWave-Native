import process from 'node:process';
import os from 'node:os';
import { CacheStore } from './cache-store.js';
import { loadConfig } from './config.js';
import { FirebaseTokenVerifier } from './firebase-auth.js';
import { createServer } from './server.js';
import { TimingRecorder } from './timings.js';
import { YtDlpClient } from './yt-dlp.js';

async function main() {
  const config = loadConfig();
  const timings = new TimingRecorder(config.diagnosticHistory);
  const resolver = new YtDlpClient({
    binaryPath: config.ytDlpPath,
    resolveTimeoutMs: config.resolveTimeoutMs,
    downloadTimeoutMs: config.downloadTimeoutMs,
    cacheTtlMs: config.resolveCacheMs,
    timings,
  });
  const cache = new CacheStore({
    root: config.cacheDir,
    maxBytes: config.cacheMaxBytes,
    maxAgeMs: config.cacheMaxAgeMs,
    concurrency: config.cacheConcurrency,
  });
  await cache.init();

  const installed = await resolver.isInstalled();
  const ytDlpVersion = installed ? await resolver.version() : null;
  if (!installed) {
    console.warn(`yt-dlp was not found at ${config.ytDlpPath}. Run npm run bootstrap before requesting audio.`);
  }

  const tokenVerifier = config.authMode === 'firebase'
    ? new FirebaseTokenVerifier({ projectId: config.firebaseProjectId })
    : null;
  const server = createServer({ config, resolver, cache, tokenVerifier, timings, ytDlpVersion });

  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(config.port, config.host, () => {
      server.removeListener('error', reject);
      resolve();
    });
  });
  console.log(`CapyFlow media backend listening on http://${config.host}:${config.port}`);
  console.log(`Authentication mode: ${config.authMode}; cache: ${config.cacheDir}`);
  if (config.allowLan) {
    const addresses = Object.entries(os.networkInterfaces()).flatMap(([name, entries]) =>
      (entries || []).filter((entry) => {
        if (entry.family !== 'IPv4' || entry.internal) return false;
        const octets = entry.address.split('.').map(Number);
        return octets[0] === 10 ||
          (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) ||
          (octets[0] === 192 && octets[1] === 168);
      }).map((entry) => `${name}: http://${entry.address}:${config.port}`));
    if (addresses.length > 0) console.log(`Private-network addresses: ${addresses.join(', ')}`);
  }

  let stopping = false;
  const stop = (signal) => {
    if (stopping) return;
    stopping = true;
    console.log(`Received ${signal}; stopping...`);
    cache.close();
    server.closeIdleConnections?.();
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(1), 10_000).unref();
  };
  process.once('SIGINT', () => stop('SIGINT'));
  process.once('SIGTERM', () => stop('SIGTERM'));
}

main().catch((error) => {
  console.error(error instanceof Error ? error.stack : error);
  process.exitCode = 1;
});
