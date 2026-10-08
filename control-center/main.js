import { app, BrowserWindow, ipcMain, dialog, shell, Tray, Menu } from 'electron';
import fs from 'node:fs/promises';
import path from 'node:path';
import http from 'node:http';
import { randomBytes } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { backendRoot, bannerID } from './policy.js';
import { firebaseConfig } from './firebase-config.js';
import { LocalBackend } from './local-backend.js';
import { publishAndroid } from './github-admin.js';
import os from 'node:os';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
const exec = promisify(execFile);

const directory = path.dirname(fileURLToPath(import.meta.url));
const smokeTest = process.argv.includes('--smoke-test');
let window, server, root = '', nonce = '', loginURL = '', idToken = '', refreshToken = '', expiresAt = 0;
let picked = null;
let localBackend, settings = {};
let tray, quitting = false;
let pendingPush = null;
async function saveSettings() {
  await fs.mkdir(app.getPath('userData'), { recursive: true });
  await fs.writeFile(path.join(app.getPath('userData'), 'settings.json'), JSON.stringify({ ...settings, backend: root }));
}
function itemID(value) { if (typeof value !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/u.test(value)) throw Error('Invalid item ID.'); return value; }
const clearSession = () => { idToken = ''; refreshToken = ''; expiresAt = 0; nonce = ''; picked = null; };
async function token(force = false) {
  if (!refreshToken) throw new Error('Sign in first.');
  if (!force && Date.now() < expiresAt) return idToken;
  const response = await fetch(`https://securetoken.googleapis.com/v1/token?key=${firebaseConfig.apiKey}`, {
    method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'refresh_token', refresh_token: refreshToken }), signal: AbortSignal.timeout(15_000),
  });
  if (!response.ok) { clearSession(); throw new Error('Your sign-in expired. Sign in again.'); }
  const result = await response.json(); idToken = result.id_token; refreshToken = result.refresh_token;
  expiresAt = Date.now() + (Number(result.expires_in) - 60) * 1000; return idToken;
}
async function request(route, { method = 'GET', body, type = 'application/json', preview = false } = {}) {
  for (let attempt = 0; attempt < 2; attempt++) {
    const response = await fetch(root + '/v1/admin/' + route, {
      method, headers: { Authorization: `Bearer ${await token(attempt > 0)}`, 'Content-Type': type },
      body, signal: AbortSignal.timeout(30_000), redirect: 'error',
    });
    if (response.status === 401 && attempt === 0) continue;
    if (!response.ok) { const result = await response.json().catch(() => ({})); throw new Error(result.error?.message || `Server request failed (${response.status}).`); }
    if (preview) return 'data:image/gif;base64,' + Buffer.from(await response.arrayBuffer()).toString('base64');
    return response.json();
  }
}
app.whenReady().then(async () => {
  try { settings = JSON.parse(await fs.readFile(path.join(app.getPath('userData'), 'settings.json'), 'utf8')); root = backendRoot(settings.backend); } catch { }
  const existingData = path.join(os.homedir(), 'CapyFlowBackend-dev11/backend');
  let dataDirectory = settings.dataDirectory;
  if (!dataDirectory) { try { await fs.access(path.join(existingData, '.env')); dataDirectory = existingData; } catch { dataDirectory = path.join(app.getPath('userData'), 'backend-data'); } }
  localBackend = new LocalBackend({ resources: app.isPackaged ? process.resourcesPath : path.join(directory, 'runtime'), dataDirectory, executable: process.execPath, logger: () => {
    if (localBackend?.publicURL && root.includes('.trycloudflare.com') && root !== localBackend.publicURL) {
      root = localBackend.publicURL; void saveSettings(); window?.webContents.send('backend-address', root);
    }
  } });
  if (!root) {
    try {
      const response = await fetch('https://raw.githubusercontent.com/sephirothkazuhakaede-hash/LastWave-Native/runtime/backend-discovery/backend.json', { signal: AbortSignal.timeout(5_000) });
      if (response.ok) root = backendRoot((await response.json()).url);
    } catch { }
  }
  server = http.createServer(async (req, res) => {
    const signInNonce = nonce;
    try {
      const expected = new URL(loginURL).host;
      if (req.headers.host !== expected) { res.writeHead(403); res.end(); return; }
      if (req.url === '/login' && req.method === 'GET') {
        res.writeHead(200, { 'Content-Type': 'text/html', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
          'Content-Security-Policy': "default-src 'self'; script-src 'self' https://apis.google.com; frame-src https://*.firebaseapp.com https://accounts.google.com; connect-src 'self' https://*.googleapis.com https://*.firebaseapp.com; style-src 'unsafe-inline'" });
        res.end('<!doctype html><title>CapyFlow Control Center sign-in</title><style>body{font:18px system-ui;background:#101318;color:#eef4ee;padding:50px}button{padding:14px;border:0;border-radius:12px;background:#a3e7b0;font:inherit}</style><h1>CapyFlow Control Center</h1><p>Sign in with your CapyFlow administrator account.</p><button>Continue with Google</button><script type="module" src="/auth.js"></script>'); return;
      }
      if (req.url === '/auth.js' && req.method === 'GET') {
        res.writeHead(200, { 'Content-Type': 'text/javascript', 'Cache-Control': 'no-store' }); res.end(await fs.readFile(path.join(directory, 'dist/auth.js'))); return;
      }
      if (req.url !== '/session' || req.method !== 'POST' || !nonce || req.headers['x-control-nonce'] !== nonce || req.headers.origin !== new URL(loginURL).origin) {
        res.writeHead(403); res.end('This sign-in session has expired. Close this tab and connect again from Control Center.'); return;
      }
      let length = 0; const chunks = [];
      for await (const chunk of req) { length += chunk.length; if (length > 32768) throw new Error('Sign-in response too large.'); chunks.push(chunk); }
      const result = JSON.parse(Buffer.concat(chunks));
      if (typeof result.idToken !== 'string' || typeof result.refreshToken !== 'string') throw new Error('Invalid sign-in response.');
      idToken = result.idToken; refreshToken = result.refreshToken; expiresAt = Date.now() + 3_300_000;
      await request('status'); nonce = ''; res.writeHead(200); res.end('Connected');
      window?.webContents.send('connected');
    } catch (error) {
      const retryNonce = nonce || signInNonce;
      clearSession(); nonce = retryNonce;
      res.writeHead(403, { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' });
      res.end(/administrator|admin|sign-in expired|sign in first/iu.test(error.message)
        ? error.message
        : 'Could not reach the backend. Check Backend & status and the server address, then try again.');
    }
  });
  server.requestTimeout = 20_000;
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  loginURL = `http://localhost:${server.address().port}/login`;
  window = new BrowserWindow({ show: !smokeTest, width: 1180, height: 820, minWidth: 850, minHeight: 650, backgroundColor: '#101318',
    webPreferences: { preload: path.join(directory, 'preload.cjs'), contextIsolation: true, nodeIntegration: false, sandbox: true } });
  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  window.webContents.on('will-navigate', event => event.preventDefault());
  await window.loadFile(path.join(directory, 'index.html'));
  if (!smokeTest) {
    tray = new Tray(await app.getFileIcon(process.execPath));
    tray.setToolTip('CapyFlow Control Center');
    tray.setContextMenu(Menu.buildFromTemplate([
      { label: 'Open Control Center', click: () => { window.show(); window.focus(); } },
      { label: 'Stop managed backend and quit', click: async () => {
        try {
          if ((await localBackend.status()).managed) await localBackend.stop();
          if (localBackend.tunnel && localBackend.tunnel.exitCode === null) localBackend.tunnel.kill();
          quitting = true; app.quit();
        } catch (error) { await dialog.showMessageBox(window, { type: 'info', message: error.message }); }
      } },
    ]));
    tray.on('double-click', () => { window.show(); window.focus(); });
    window.on('close', event => {
      if (!quitting && (localBackend.child?.exitCode === null || localBackend.tunnel?.exitCode === null)) { event.preventDefault(); window.hide(); }
    });
  }
  if (smokeTest) { console.log('CapyFlow Control Center window loaded.'); clearSession(); server.close(); app.exit(0); }
});
function trusted(event) {
  if (!window || event.sender !== window.webContents || event.senderFrame !== window.webContents.mainFrame) throw new Error('Untrusted window.');
}
ipcMain.handle('control', async (event, action, value) => {
  trusted(event);
  switch (action) {
    case 'settings': return { backend: root, connected: Boolean(refreshToken), dataDirectory: localBackend.dataDirectory };
    case 'connect': {
      root = backendRoot(value); clearSession(); nonce = randomBytes(32).toString('hex');
      await saveSettings();
      await shell.openExternal(loginURL + '#' + nonce); return true;
    }
    case 'logout': clearSession(); return true;
    case 'list': return request('banners');
    case 'status': return request('status');
    case 'users': return request(`users?q=${encodeURIComponent(value?.query || '')}&page=${encodeURIComponent(value?.page || '')}`);
    case 'set-user': return request(`users/${itemID(value.uid)}`, { method: 'PATCH', body: JSON.stringify({ disabled: value.disabled }) });
    case 'messages': return request('global-messages');
    case 'moderate': return request(`global-messages/${itemID(value.id)}`, { method: 'PATCH', body: JSON.stringify({ restore: value.restore }) });
    case 'announcements': return request('announcements');
    case 'save-announcement': return request(`announcements/${itemID(value.id)}`, { method: 'PUT', body: JSON.stringify({ title: value.title, body: value.body, published: value.published }) });
    case 'push-preview': return request('push');
    case 'send-push': {
      const fingerprint = JSON.stringify([value.title, value.body]);
      if (!pendingPush || pendingPush.fingerprint !== fingerprint) pendingPush = { fingerprint, id: randomBytes(16).toString('hex') };
      const result = await request('push', { method: 'POST', body: JSON.stringify({ id: pendingPush.id, title: value.title, body: value.body }) });
      pendingPush = null; return result;
    }
    case 'audit': return request('audit');
    case 'local-status': return localBackend.status();
    case 'local-start': return localBackend.start();
    case 'local-stop': return localBackend.stop();
    case 'local-restart': return localBackend.restart();
    case 'local-folder': {
      const result = await dialog.showOpenDialog(window, { properties: ['openDirectory'], title: 'Choose your existing CapyFlow backend data folder' });
      if (result.canceled) return null;
      await fs.access(path.join(result.filePaths[0], '.env'));
      if ((await localBackend.status()).managed) throw Error('Stop the managed backend before changing its data folder.');
      localBackend.dataDirectory = result.filePaths[0]; settings.dataDirectory = localBackend.dataDirectory; await saveSettings(); return localBackend.status();
    }
    case 'releases': {
      const response = await fetch('https://api.github.com/repos/sephirothkazuhakaede-hash/LastWave-Native/releases?per_page=20', { headers: { 'User-Agent': 'CapyFlow-Control-Center' }, signal: AbortSignal.timeout(15000) });
      if (!response.ok) throw Error('Could not load published app updates.');
      const releases = await response.json(); return releases.filter(release => !release.draft).map(release => ({ name: release.name, tag: release.tag_name, prerelease: release.prerelease, notes: release.body?.slice(0,6000) ?? '', publishedAt: release.published_at }));
    }
    case 'release-notes': {
      await request('status');
      if (!/^android-dev[0-9]+$/u.test(value.tag) || typeof value.notes !== 'string' || !value.notes.trim() || value.notes.length > 6000) throw Error('Choose an Android release and notes of up to 6,000 characters.');
      const url = `https://github.com/sephirothkazuhakaede-hash/LastWave-Native/releases/download/${value.tag}/android-update.json`;
      const response = await fetch(url, { signal: AbortSignal.timeout(15000) });
      if (!response.ok) throw Error('The Android update manifest is unavailable.');
      const bytes = Buffer.from(await response.arrayBuffer()); if (bytes.length > 100000) throw Error('Unexpected update manifest size.');
      const manifest = JSON.parse(bytes);
      if (String(manifest.versionCode) !== value.tag.slice(11) || !/^[a-f0-9]{64}$/u.test(manifest.sha256 || '') || manifest.apkURL !== url.replace('android-update.json', 'CapyFlow.apk')) throw Error('Unexpected update metadata.');
      manifest.releaseNotes = value.notes.trim();
      const folder = await fs.mkdtemp(path.join(os.tmpdir(), 'capyflow-release-'));
      const manifestFile = path.join(folder, 'android-update.json'), notesFile = path.join(folder, 'notes.txt');
      try {
        await fs.writeFile(manifestFile, JSON.stringify(manifest, null, 2)); await fs.writeFile(notesFile, manifest.releaseNotes);
        await exec('gh.exe', ['release', 'upload', value.tag, manifestFile, '--clobber', '--repo', 'sephirothkazuhakaede-hash/LastWave-Native'], { windowsHide: true, timeout: 30000 });
        await exec('gh.exe', ['release', 'edit', value.tag, '--notes-file', notesFile, '--repo', 'sephirothkazuhakaede-hash/LastWave-Native'], { windowsHide: true, timeout: 30000 });
      } finally { await fs.unlink(manifestFile).catch(() => {}); await fs.unlink(notesFile).catch(() => {}); await fs.rmdir(folder).catch(() => {}); }
      return { note: 'Android release notes updated. The APK, version number and checksum are unchanged.' };
    }
    case 'publish-android': {
      await request('status');
      return publishAndroid(value);
    }
    case 'pick': {
      const selection = await dialog.showOpenDialog(window, { properties: ['openFile'], filters: [{ name: 'Animated GIF', extensions: ['gif'] }] });
      if (selection.canceled) return null;
      const info = await fs.stat(selection.filePaths[0]); if (info.size > 5 * 1024 * 1024) throw new Error('Choose a GIF of up to 5 MB.');
      picked = await fs.readFile(selection.filePaths[0]);
      if (!['GIF87a', 'GIF89a'].includes(picked.toString('ascii', 0, 6))) { picked = null; throw new Error('Choose a GIF file.'); }
      return { fileName: path.basename(selection.filePaths[0]), preview: 'data:image/gif;base64,' + picked.toString('base64') };
    }
    case 'upload': {
      if (!picked) throw new Error('Choose a GIF first.');
      const id = bannerID(value.id);
      const result = await request(`banners/${id}?name=${encodeURIComponent(value.name)}`, { method: 'POST', type: 'image/gif', body: picked });
      picked = null; return result;
    }
    case 'update': return request(`banners/${bannerID(value.id)}`, { method: 'PATCH', body: JSON.stringify(value.patch) });
    case 'delete': return request(`banners/${bannerID(value)}`, { method: 'DELETE' });
    case 'preview': {
      if (!/^[a-f0-9]{64}$/u.test(value.revision)) throw new Error('Invalid banner revision.');
      return request(`banners/${bannerID(value.id)}/${value.revision}.gif`, { preview: true });
    }
    default: throw new Error('Unknown Control Center operation.');
  }
});
app.on('window-all-closed', () => { clearSession(); server?.close(); app.quit(); });
