import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,mkdirSync,writeFileSync,readFileSync,chmodSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';

function exercise(mode,answer=''){
 const root=mkdtempSync(join(tmpdir(),'capy-migrate-'));
 try{
  const fixture=join(root,'fixture');mkdirSync(fixture);mkdirSync(join(fixture,'files'));mkdirSync(join(fixture,'shared_prefs'));
  writeFileSync(join(fixture,'files','offline.audio'),Buffer.alloc(4096,71));writeFileSync(join(fixture,'shared_prefs','capyflow.xml'),'<playlist>Keep me</playlist>');
  const packed=spawnSync('tar',['-cf','-', '-C',fixture,'files','shared_prefs']);assert.equal(packed.status,0);
  writeFileSync(join(root,'fixture.tar'),packed.stdout);writeFileSync(join(root,'new.apk'),'fixture');
  const fake=join(root,'fake-adb');
  writeFileSync(fake,`#!/usr/bin/env node
import {readFileSync,writeFileSync,appendFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
const args=process.argv.slice(2),root=process.env.CAPY_TEST_ROOT,mode=process.env.CAPY_TEST_MODE;
appendFileSync(root+'/calls',JSON.stringify(args)+'\\n');
if(args[0]==='exec-out'){process.stdout.write(mode==='bad-backup'?Buffer.from('bad'):readFileSync(root+'/fixture.tar'));process.exit(0)}
if(args.includes('-tf')){const r=spawnSync('tar',['-tf','-'],{input:readFileSync(0)});process.exit(r.status)}
if(args.includes('-xf')){writeFileSync(root+'/restored.tar',readFileSync(0));process.exit(0)}
if(args[0]==='install' && args.includes('-r') && mode!=='compatible'){console.error(mode==='other-error'?'INSTALL_FAILED_INVALID_APK':'INSTALL_FAILED_UPDATE_INCOMPATIBLE');process.exit(1)}
console.log('Success');
`);chmodSync(fake,0o755);
  const r=spawnSync(process.execPath,[new URL('./migrate-preview.mjs',import.meta.url).pathname,join(root,'new.apk'),join(root,'backups')],{input:answer,encoding:'utf8',env:{...process.env,CAPYFLOW_ADB:fake,CAPY_TEST_ROOT:root,CAPY_TEST_MODE:mode}});
  const calls=readFileSync(join(root,'calls'),'utf8').trim().split('\n').map(JSON.parse);
  const removed=calls.some(c=>c[0]==='uninstall');
  const restored=calls.some(c=>c.includes('-xf'));
  if(restored)assert.deepEqual(readFileSync(join(root,'restored.tar')),packed.stdout);
  return {r,removed,restored,calls};
 }finally{rmSync(root,{recursive:true,force:true})}
}
test('compatible updates preserve data without uninstall',()=>{const x=exercise('compatible');assert.equal(x.r.status,0,x.r.stderr);assert.equal(x.removed,false)});
test('declining migration keeps the old app and backup',()=>{const x=exercise('mismatch','NO\n');assert.equal(x.r.status,0,x.r.stderr);assert.equal(x.removed,false);assert.equal(x.restored,false)});
test('only explicit migration replaces the old app and restores every byte',()=>{const x=exercise('mismatch','MIGRATE\n');assert.equal(x.r.status,0,x.r.stderr);assert.equal(x.removed,true);assert.equal(x.restored,true);assert(x.calls.some(c=>c.includes('-tf')))});
test('invalid backup prevents uninstall',()=>{const x=exercise('bad-backup','MIGRATE\n');assert.notEqual(x.r.status,0);assert.equal(x.removed,false)});
test('other install failures never trigger uninstall',()=>{const x=exercise('other-error','MIGRATE\n');assert.notEqual(x.r.status,0);assert.equal(x.removed,false)});
