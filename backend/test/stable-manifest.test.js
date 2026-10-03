import { test } from 'node:test';
import assert from 'node:assert/strict';
import { stableManifest } from '../scripts/stable-manifest.mjs';
const input = { stable: true, version: '0.4.6', build: 13, releaseNotes: 'Release fixture', installURL: 'https://github.com/sephirothkazuhakaede-hash/LastWave-Native/releases/tag/capyflow-v0.4.6' };
test('stable manifest requires deliberate stable publication and numeric metadata', () => {
  assert.equal(stableManifest(input).channel, 'stable');
  for (const update of [{ stable: false }, { version: '0.4.6-beta' }, { version: 'v0.4.6' }, { build: 0 }, { build: 13.5 }, { installURL: 'http://example.com' }, { releaseNotes: '' }]) {
    assert.throws(() => stableManifest({ ...input, ...update }));
  }
});
