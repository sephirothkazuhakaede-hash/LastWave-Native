import { spawn } from 'node:child_process';
import { releaseInput } from './policy.js';
const repo = 'sephirothkazuhakaede-hash/LastWave-Native', branch = 'feature/capyflow-android';
async function github(method, route, value) {
  const args = ['api', '--method', method, `repos/${repo}/${route}`]; if (value) args.push('--input', '-');
  return new Promise((resolve, reject) => {
    const child = spawn('gh.exe', args, { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
    let output = '', length = 0;
    const timer = setTimeout(() => { child.kill(); reject(Error('GitHub request timed out.')); }, 30000);
    child.stdout.on('data', bytes => { length += bytes.length; if (length > 4 * 1024 * 1024) { child.kill(); return; } output += bytes.toString(); });
    child.stderr.resume(); child.stdin.end(value ? JSON.stringify(value) : undefined);
    child.once('error', () => { clearTimeout(timer); reject(Error('GitHub CLI is unavailable. Install it and sign in on this PC.')); });
    child.once('exit', code => { clearTimeout(timer); if (code !== 0 || length > 4 * 1024 * 1024) { reject(Error('GitHub request failed. Check this PC’s GitHub CLI sign-in and repository permissions.')); return; } try { resolve(JSON.parse(output)); } catch { reject(Error('Unexpected GitHub response.')); } });
  });
}
export async function publishAndroid(value, request = github) {
  const release = releaseInput(value);
  const ref = await request('GET', 'git/ref/heads/' + branch);
  const commit = await request('GET', 'git/commits/' + ref.object.sha);
  const paths = ['capyflow-android/app/build.gradle.kts'];
  const files = await Promise.all(paths.map(async path => {
    const file = await request('GET', `contents/${path}?ref=${ref.object.sha}`);
    if (file.encoding !== 'base64') throw Error('Unexpected Android source format.');
    return Buffer.from(file.content, 'base64').toString('utf8');
  }));
  const currentCode = Number(files[0].match(/versionCode\s*=\s*(\d+)/u)?.[1]);
  const currentName = files[0].match(/versionName\s*=\s*"([0-9.]+)"/u)?.[1];
  const releases = await request('GET', 'releases?per_page=100');
  const highest = Math.max(currentCode || 0, ...releases.map(item => /^android-dev(\d+)$/u.exec(item.tag_name)?.[1]).filter(Boolean).map(Number));
  if (!currentName || release.versionCode <= highest) throw Error(`Choose a build number higher than ${highest}.`);
  const oldParts = currentName.split('.').map(Number), newParts = release.versionName.split('.').map(Number);
  let newer = false;
  for (let i = 0; i < 3; i++) { if (newParts[i] > oldParts[i]) { newer = true; break; } if (newParts[i] < oldParts[i]) break; }
  if (!newer) throw Error(`Choose a version newer than ${currentName}.`);
  const tree = await request('POST', 'git/trees', { base_tree: commit.tree.sha, tree: [
    { path: paths[0], mode: '100644', type: 'blob', content: files[0].replace(/versionCode\s*=\s*\d+/u, `versionCode = ${release.versionCode}`).replace(/versionName\s*=\s*"[0-9.]+"/u, `versionName = "${release.versionName}"`) },
    { path: 'capyflow-android/android-release-notes.txt', mode: '100644', type: 'blob', content: `CapyFlow ${release.versionName} — Stable\n\n${release.notes}\n` },
  ] });
  const next = await request('POST', 'git/commits', { message: `Publish CapyFlow ${release.versionName} from Control Center [publish-android-stable]`, tree: tree.sha, parents: [ref.object.sha] });
  // A concurrent branch update makes this non-fast-forward and is rejected; never force a release commit.
  await request('PATCH', 'git/refs/heads/' + branch, { sha: next.sha, force: false });
  return { note: `CapyFlow ${release.versionName} (build ${release.versionCode}) is queued. It becomes public only after the existing build and security checks pass.`, commit: next.sha };
}
