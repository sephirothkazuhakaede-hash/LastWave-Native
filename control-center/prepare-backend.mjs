// Package source and public runtime tools only. Credentials and mutable data are never copied.
import fs from 'node:fs/promises';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
const root = path.resolve(import.meta.dirname, '..'), output = path.join(import.meta.dirname, 'bundled-backend');
await fs.mkdir(output, { recursive: true });
for (const folder of ['src', 'assets']) await fs.cp(path.join(root, 'backend', folder), path.join(output, folder), { recursive: true, filter: file => !file.endsWith('.backup') });
await fs.copyFile(path.join(root, 'backend/package.json'), path.join(output, 'package.json'));
try { await fs.copyFile(path.join(root, 'LICENSE'), path.join(output, 'LICENSE')); } catch (error) { if (error.code !== 'ENOENT') throw error; }
const npm = process.platform === 'win32' ? 'npm.cmd' : 'npm';
await new Promise((resolve, reject) => {
  const child = spawn(npm, ['install', '--omit=dev', '--ignore-scripts', '--no-audit', '--no-fund'], { cwd: output, stdio: 'inherit', shell: process.platform === 'win32' });
  child.once('error', reject); child.once('exit', code => code === 0 ? resolve() : reject(Error('Bundled backend dependencies failed.')));
});
const tools = path.join(import.meta.dirname, 'bundled-tools'); await fs.mkdir(tools, { recursive: true });
await fs.writeFile(path.join(tools, 'THIRD-PARTY-NOTICES.txt'), 'CapyFlow backend source is available in the LastWave-Native repository under its GPL-3.0-only license.\nCloudflared: https://github.com/cloudflare/cloudflared (Apache-2.0; see LICENSE and NOTICE in its source repository).\nyt-dlp: https://github.com/yt-dlp/yt-dlp (see LICENSE, Unlicense and THIRD_PARTY_LICENSES in its source repository; the Windows standalone executable includes third-party runtime components).\nExact tool releases, source URLs and verified SHA-256 digests are recorded in the adjacent .source.json files.\n');
for (const [repository, name, destination] of [
  ['cloudflare/cloudflared', 'cloudflared-windows-amd64.exe', 'cloudflared.exe'],
  ['yt-dlp/yt-dlp', 'yt-dlp.exe', 'yt-dlp.exe'],
]) {
  const existing = path.join(tools, destination);
  try { if ((await fs.stat(existing)).size > 100000) continue; } catch {}
  const releaseResponse = await fetch(`https://api.github.com/repos/${repository}/releases/latest`, { headers: { 'User-Agent': 'CapyFlow-Control-Center-Build', ...(process.env.GITHUB_TOKEN ? { Authorization: `Bearer ${process.env.GITHUB_TOKEN}` } : {}) }, signal: AbortSignal.timeout(30000) });
  if (!releaseResponse.ok) throw Error(`Could not load ${repository} runtime release (${releaseResponse.status}).`);
  const release = await releaseResponse.json(), asset = release.assets.find(asset => asset.name === name);
  if (!asset || !/^sha256:[a-f0-9]{64}$/u.test(asset.digest ?? '')) throw Error(`Missing verified checksum for ${name}.`);
  const response = await fetch(asset.browser_download_url, { signal: AbortSignal.timeout(120000) });
  if (!response.ok) throw Error(`Could not download ${name}.`);
  const bytes = Buffer.from(await response.arrayBuffer());
  if (createHash('sha256').update(bytes).digest('hex') !== asset.digest.slice(7)) throw Error(`Runtime checksum mismatch: ${name}.`);
  await fs.writeFile(existing, bytes);
  await fs.writeFile(path.join(tools, destination + '.source.json'), JSON.stringify({ repository, release: release.tag_name, sha256: asset.digest.slice(7), url: asset.browser_download_url }, null, 2));
}
