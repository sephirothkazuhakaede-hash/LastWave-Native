import { readFile, writeFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

export function stableManifest({ version, build, releaseNotes, installURL, stable }) {
  if (!stable) throw new Error('Explicit --stable is required. Experimental builds must never publish a stable manifest.');
  if (!/^\d+\.\d+(?:\.\d+){0,2}$/u.test(version) || !Number.isSafeInteger(build) || build <= 0) throw new Error('Invalid numeric version/build.');
  const url = new URL(installURL);
  if (url.protocol !== 'https:' || url.username || url.password || !releaseNotes.trim()) throw new Error('HTTPS install destination and release notes are required.');
  return { schemaVersion: 1, channel: 'stable', version, build, releaseNotes: releaseNotes.trim(), installURL: url.href };
}
async function main() {
  const args = process.argv.slice(2), options = {};
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--stable') options.stable = true;
    else if (['--version', '--build', '--notes-file', '--install-url', '--output'].includes(args[i])) options[args[i].slice(2)] = args[++i];
    else throw new Error(`Unknown option: ${args[i]}`);
  }
  if (!options.output || !options['notes-file']) throw new Error('--output and --notes-file are required.');
  const result = stableManifest({ stable: options.stable, version: options.version, build: Number(options.build),
    releaseNotes: await readFile(options['notes-file'], 'utf8'), installURL: options['install-url'] });
  await writeFile(options.output, JSON.stringify(result, null, 2) + '\n');
  console.log(`Created ${options.output} for stable CapyFlow ${result.version} (${result.build}). Nothing was published.`);
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main().catch(error => { console.error(error.message); process.exitCode = 1; });
