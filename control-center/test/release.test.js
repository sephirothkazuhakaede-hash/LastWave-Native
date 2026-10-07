import { test } from 'node:test';
import assert from 'node:assert/strict';
import { releaseInput } from '../policy.js';
import { publishAndroid } from '../github-admin.js';
test('release inputs cannot inject branch names, paths, or invalid version/build metadata', () => {
  assert.equal(releaseInput({ versionName: '1.0.10', versionCode: 23, notes: 'New content' }).versionCode, 23);
  for (const value of [{versionName:'1.0.10;command',versionCode:23,notes:'x'}, {versionName:'1.0.10',versionCode:22.5,notes:'x'}, {versionName:'1.0.10',versionCode:23,notes:''}, {versionName:'1.0.10',versionCode:2147483647,notes:'x'}]) assert.throws(() => releaseInput(value));
});
test('publishing changes only version and notes, preserves source, and never force-updates a concurrent branch', async () => {
  const calls = []; const source = 'defaultConfig { versionCode = 22; versionName = "1.0.9" }\n// Keep every existing dependency and feature';
  const request = async (method, route, value) => {
    calls.push({method,route,value});
    if (route.startsWith('git/ref/')) return {object:{sha:'head'}};
    if (route === 'git/commits/head') return {tree:{sha:'base-tree'}};
    if (route.startsWith('contents/')) return {encoding:'base64',content:Buffer.from(source).toString('base64')};
    if (route.startsWith('releases?')) return [{tag_name:'android-dev22'}];
    if (route === 'git/trees') return {sha:'next-tree'};
    if (route === 'git/commits') return {sha:'next-commit'};
    if (route.startsWith('git/refs/')) { assert.equal(value.force,false); return {}; }
    throw Error('Unexpected request');
  };
  await publishAndroid({versionName:'1.0.10',versionCode:23,notes:'Compact admin publishing'},request);
  const tree=calls.find(call=>call.route==='git/trees').value;
  assert.equal(tree.tree.length,2); assert.match(tree.tree[0].content,/versionCode = 23; versionName = "1.0.10"/u);
  assert.match(tree.tree[0].content,/Keep every existing dependency and feature/u);
  assert.match(calls.find(call=>call.route==='git/commits').value.message,/\[publish-android-stable\]/u);
  calls.length=0;
  await assert.rejects(publishAndroid({versionName:'1.0.10',versionCode:22,notes:'Duplicate build'},request));
  assert.equal(calls.some(call=>call.method!=='GET'),false);
  await assert.rejects(publishAndroid({versionName:'1.0.8',versionCode:24,notes:'Older version'},request));
  assert.equal(calls.some(call=>call.method!=='GET'),false);
});
