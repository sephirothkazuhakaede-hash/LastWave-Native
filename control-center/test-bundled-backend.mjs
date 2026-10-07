import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { createRequire } from 'node:module';
const root = path.resolve(import.meta.dirname, 'dist/win-unpacked');
const resources = path.join(root, 'resources/backend'), data = await fs.mkdtemp(path.join(os.tmpdir(), 'capyflow-package-test-'));
const require = createRequire(path.join(resources, 'package.json'));
for (const module of ['firebase-admin/app', 'firebase-admin/auth', 'firebase-admin/firestore', 'firebase-admin/messaging']) require(module);
await fs.writeFile(path.join(data, '.env'), 'AUTH_MODE=local\nPUSH_NOTIFICATIONS=false\n');
const child = spawn(path.join(root, 'CapyFlow Control Center.exe'), [path.join(resources, 'src/index.js')], { cwd: data, windowsHide: true, env: { ...process.env, ELECTRON_RUN_AS_NODE: '1', CAPYFLOW_DATA_DIR: data, CAPYFLOW_ENV_FILE: path.join(data, '.env'), FIREBASE_PROJECT_ID: '', PUSH_NOTIFICATIONS: 'false', BIND_HOST: '127.0.0.1', PORT: '18887', YTDLP_PATH: path.join(root, 'resources/tools/yt-dlp.exe') }, stdio: ['ignore', 'ignore', 'ignore', 'ipc'] });
const exited = new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', resolve); });
let timer;
try {
  let ready = false;
  for (let i = 0; i < 40; i++) { try { ready = (await fetch('http://127.0.0.1:18887/health', { signal: AbortSignal.timeout(500) })).ok; } catch {} if (ready) break; await new Promise(resolve => setTimeout(resolve, 250)); }
  if (!ready) throw Error('Packaged backend did not start.');
  const health = await (await fetch('http://127.0.0.1:18887/health')).json();
  const catalog = await (await fetch('http://127.0.0.1:18887/v1/profile-banners')).json();
  if (!health.ytDlp.installed || catalog.banners[0]?.frames < 2) throw Error('Packaged resolver/animated fallback is missing.');
  child.send({ type: 'capyflow-shutdown' });
  const code = await Promise.race([exited, new Promise((_, reject) => { timer = setTimeout(() => reject(Error('Graceful shutdown timed out.')), 12000); })]);
  if (code !== 0) throw Error('Graceful shutdown failed.');
  console.log('Packaged Firebase modules, music resolver, animated fallback, startup and graceful shutdown passed with synthetic settings.');
} finally { clearTimeout(timer); if (child.exitCode === null) child.kill(); }
