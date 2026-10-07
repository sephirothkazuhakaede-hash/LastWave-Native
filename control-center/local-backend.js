import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { randomUUID } from 'node:crypto';
import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
const exec = promisify(execFile);
export class LocalBackend {
  constructor({ resources, dataDirectory, executable, logger = () => {} }) {
    this.resources = resources; this.dataDirectory = dataDirectory; this.executable = executable; this.logger = logger;
    this.child = null; this.tunnel = null; this.lines = []; this.publicURL = ''; this.exitError = ''; this.publication = '';
  }
  log(line) { this.lines.push(line.replace(/Bearer\s+\S+/giu, 'Bearer [redacted]').slice(0, 500)); this.lines = this.lines.slice(-80); this.logger(); }
  async health() { try { const r = await fetch('http://127.0.0.1:8787/health', { signal: AbortSignal.timeout(1500) }); return r.ok ? await r.json() : null; } catch { return null; } }
  async status() { return { healthy: Boolean(await this.health()), managed: Boolean(this.child && this.child.exitCode === null), dataDirectory: this.dataDirectory, publicURL: this.publicURL, tunnelManaged: Boolean(this.tunnel && this.tunnel.exitCode === null), publication: this.publication, exitError: this.exitError, logs: this.lines }; }
  async start() {
    if (await this.health()) return { ...await this.status(), note: 'The existing backend is already running. Use Restart with bundled backend to switch safely.' };
    const source = path.join(this.resources, 'backend/src/index.js'), tools = path.join(this.resources, 'tools');
    await fs.access(source); await fs.mkdir(this.dataDirectory, { recursive: true });
    const environment = path.join(this.dataDirectory, '.env');
    try { await fs.access(environment); } catch { throw Error('Choose your existing backend folder first so its Firebase and music settings can be reused.'); }
    this.exitError = '';
    const envText = await fs.readFile(environment, 'utf8');
    const configuredTool = /^YTDLP_PATH=(.*)$/mu.exec(envText)?.[1]?.trim().replace(/^["']|["']$/gu, '');
    const toolPath = configuredTool ? path.resolve(this.dataDirectory, configuredTool) : path.join(tools, 'yt-dlp.exe');
    let resolvedTool = toolPath; try { await fs.access(toolPath); } catch { resolvedTool = path.join(tools, 'yt-dlp.exe'); }
    this.child = spawn(this.executable, [source, '--capyflow-data=' + this.dataDirectory], { cwd: this.dataDirectory, windowsHide: true, env: { ...process.env, ELECTRON_RUN_AS_NODE: '1', CAPYFLOW_DATA_DIR: this.dataDirectory, CAPYFLOW_ENV_FILE: environment, YTDLP_PATH: resolvedTool, BIND_HOST: '127.0.0.1', PORT: '8787' }, stdio: ['ignore', 'pipe', 'pipe', 'ipc'] });
    this.child.on('error', error => { this.exitError = error.message; this.log('Backend could not start.'); });
    for (const stream of [this.child.stdout, this.child.stderr]) stream.on('data', bytes => { for (const line of bytes.toString().split(/\r?\n/u).filter(Boolean)) this.log(line); });
    this.child.on('exit', code => { if (code) this.exitError = `Backend exited (${code}).`; this.log(`Backend stopped (${code}).`); });
    for (let i = 0; i < 40; i++) { if (await this.health()) { await this.ensureTunnel(tools); return this.status(); } if (this.child.exitCode !== null) throw Error(this.exitError || 'Backend stopped during startup.'); await new Promise(resolve => setTimeout(resolve, 500)); }
    throw Error('Backend did not become healthy. Check the server log.');
  }
  async stop() {
    const health = await this.health();
    if (!health) return this.status();
    if (health.cache?.jobs?.active || health.cache?.jobs?.pending || health.resolver?.inFlight) throw Error('Music downloads or resolutions are active. Wait for them to finish before restarting.');
    if (this.child && this.child.exitCode === null) {
      this.child.send({ type: 'capyflow-shutdown' });
      const child = this.child;
      await Promise.race([new Promise(resolve => child.once('exit', resolve)), new Promise((_, reject) => setTimeout(() => reject(Error('Backend is still shutting down. Try again shortly.')), 12000))]);
    } else {
      // Only adopt the explicitly chosen existing backend. Never kill a process by port alone.
      const script = `param([string]$Folder)\n$ErrorActionPreference='Stop'\n$listener=Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort 8787 -State Listen | Select-Object -First 1\nif(-not $listener){exit 0}\n$backend=Get-CimInstance Win32_Process -Filter (\"ProcessId = \"+$listener.OwningProcess)\n$parent=Get-CimInstance Win32_Process -Filter (\"ProcessId = \"+$backend.ParentProcessId)\n$validCommand=$backend.CommandLine -match '(?i)(src[\\\\/]index\\.js)'\n$expectedParent=$parent.CommandLine -and $parent.CommandLine.Contains($Folder)\n$expectedCommand=$backend.CommandLine -and $backend.CommandLine.Contains($Folder)\nif(-not $validCommand -or (-not $expectedParent -and -not $expectedCommand)){throw 'The running backend was not started from the selected folder. Stop it manually once, then use Start.'}\nif([IO.Path]::GetFileName($backend.ExecutablePath) -notin @('node.exe','CapyFlow Control Center.exe')){throw 'Unexpected backend executable'}\nStop-Process -Id $backend.ProcessId\n`;
      const scriptPath = path.join(os.tmpdir(), 'capyflow-stop-' + randomUUID() + '.ps1');
      await fs.writeFile(scriptPath, script);
      try { await exec('powershell.exe', ['-NoProfile', '-File', scriptPath, '-Folder', this.dataDirectory], { windowsHide: true, timeout: 15000 }); }
      finally { await fs.unlink(scriptPath).catch(() => {}); }
    }
    return this.status();
  }
  async restart() { await this.stop(); return this.start(); }
  async ensureTunnel(tools) {
    const script = "Get-CimInstance Win32_Process -Filter \"Name = 'cloudflared.exe'\" | Where-Object { $_.CommandLine -match 'localhost:8787|127\\.0\\.0\\.1:8787' } | Select-Object -ExpandProperty ProcessId";
    const found = await exec('powershell.exe', ['-NoProfile', '-Command', script], { windowsHide: true, timeout: 10000 }).catch(() => ({ stdout: '' }));
    if (found.stdout.trim()) { this.log('Keeping the existing Cloudflare tunnel.'); return; }
    if (this.tunnel && this.tunnel.exitCode === null) return;
    this.tunnel = spawn(path.join(tools, 'cloudflared.exe'), ['tunnel', '--url', 'http://localhost:8787', '--no-autoupdate'], { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    this.tunnel.on('error', () => { this.exitError = 'Public tunnel could not start.'; });
    this.tunnel.stdout.resume();
    let pending = '';
    this.tunnel.stderr.on('data', bytes => { pending += bytes.toString(); const lines = pending.split(/\r?\n/u); pending = lines.pop(); for (const line of lines) {
      const url = line.match(/https:\/\/[a-z0-9-]+\.trycloudflare\.com/u)?.[0];
      if (url && url !== this.publicURL) { this.publicURL = url; void this.publishDiscovery(url); }
      if (/error|failed/iu.test(line)) this.log(line);
    } });
  }
  async publishDiscovery(url) {
    try {
      const repo = 'sephirothkazuhakaede-hash/LastWave-Native', branch = 'runtime/backend-discovery';
      const read = await exec('gh.exe', ['api', `repos/${repo}/contents/backend.json?ref=${encodeURIComponent(branch)}`, '--jq', '.sha'], { windowsHide: true, timeout: 15000 });
      const input = JSON.stringify({ message: 'Update active CapyFlow backend', content: Buffer.from(JSON.stringify({ url, updatedAt: new Date().toISOString() })).toString('base64'), branch, sha: read.stdout.trim() });
      await new Promise((resolve, reject) => { const child = spawn('gh.exe', ['api', '--method', 'PUT', `repos/${repo}/contents/backend.json`, '--input', '-'], { windowsHide: true, stdio: ['pipe', 'ignore', 'pipe'] }); child.stdin.end(input); child.once('error', reject); child.once('exit', code => code === 0 ? resolve() : reject(Error('GitHub discovery update failed.'))); });
      this.publication = 'Published to mobile discovery'; this.log('Public connection updated for iOS and Android.');
    } catch { this.publication = 'GitHub CLI sign-in is required to publish the public connection. Run gh auth login once on this PC.'; this.log(this.publication); }
  }
}
