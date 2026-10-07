import { app, BrowserWindow, ipcMain, dialog, shell } from 'electron';
import fs from 'node:fs/promises';
import path from 'node:path';
import http from 'node:http';
import { randomBytes } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { backendRoot, bannerID } from './policy.js';
import { firebaseConfig } from './firebase-config.js';

const directory = path.dirname(fileURLToPath(import.meta.url));
let window, server, root = '', nonce = '', loginURL = '', idToken = '', refreshToken = '', expiresAt = 0;
let picked = null;
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
  try { root = backendRoot(JSON.parse(await fs.readFile(path.join(app.getPath('userData'), 'settings.json'), 'utf8')).backend); } catch { }
  server = http.createServer(async (req, res) => {
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
        res.writeHead(403); res.end(); return;
      }
      let length = 0; const chunks = [];
      for await (const chunk of req) { length += chunk.length; if (length > 32768) throw new Error('Sign-in response too large.'); chunks.push(chunk); }
      const result = JSON.parse(Buffer.concat(chunks));
      if (typeof result.idToken !== 'string' || typeof result.refreshToken !== 'string') throw new Error('Invalid sign-in response.');
      idToken = result.idToken; refreshToken = result.refreshToken; expiresAt = Date.now() + 3_300_000;
      await request('status'); nonce = ''; res.writeHead(200); res.end('Connected');
      window?.webContents.send('connected');
    } catch { clearSession(); res.writeHead(403); res.end('Could not connect this administrator.'); }
  });
  server.requestTimeout = 20_000;
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  loginURL = `http://localhost:${server.address().port}/login`;
  window = new BrowserWindow({ width: 1180, height: 820, minWidth: 850, minHeight: 650, backgroundColor: '#101318',
    webPreferences: { preload: path.join(directory, 'preload.cjs'), contextIsolation: true, nodeIntegration: false, sandbox: true } });
  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  window.webContents.on('will-navigate', event => event.preventDefault());
  await window.loadFile(path.join(directory, 'index.html'));
});
function trusted(event) {
  if (!window || event.sender !== window.webContents || event.senderFrame !== window.webContents.mainFrame) throw new Error('Untrusted window.');
}
ipcMain.handle('control', async (event, action, value) => {
  trusted(event);
  switch (action) {
    case 'settings': return { backend: root, connected: Boolean(refreshToken) };
    case 'connect': {
      root = backendRoot(value); clearSession(); nonce = randomBytes(32).toString('hex');
      await fs.mkdir(app.getPath('userData'), { recursive: true });
      await fs.writeFile(path.join(app.getPath('userData'), 'settings.json'), JSON.stringify({ backend: root }));
      await shell.openExternal(loginURL + '#' + nonce); return true;
    }
    case 'logout': clearSession(); return true;
    case 'list': return request('banners');
    case 'status': return request('status');
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
