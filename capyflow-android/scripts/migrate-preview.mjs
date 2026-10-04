#!/usr/bin/env node
// Local, streaming migration between differently signed preview APKs.
// No app data is transmitted to a server. Requires USB debugging and Node 18+.
import {spawn,spawnSync} from 'node:child_process';
import {createReadStream,createWriteStream,existsSync,mkdirSync,statSync,writeFileSync} from 'node:fs';
import {pipeline} from 'node:stream/promises';
import {once} from 'node:events';
import {resolve,join} from 'node:path';
import {createHash} from 'node:crypto';
import {createInterface} from 'node:readline/promises';

const apk=process.argv[2] && resolve(process.argv[2]);
const adb=process.env.CAPYFLOW_ADB || 'adb';
const pkg='com.seph.capyflow';
function run(args,allowFailure=false){
  const r=spawnSync(adb,args,{encoding:'utf8'});
  if(r.error)throw r.error;
  const output=(r.stdout||'')+(r.stderr||'');
  if(r.status!==0&&!allowFailure)throw Error(output.trim()||'ADB command failed');
  return {status:r.status,output};
}
async function backup(destination){
  const child=spawn(adb,['exec-out','run-as',pkg,'tar','-cf','-','files','shared_prefs'],{stdio:['ignore','pipe','inherit']});
  const closed=once(child,'close');
  await pipeline(child.stdout,createWriteStream(destination,{flags:'wx'}));
  const [code]=await closed;if(code!==0)throw Error('Backup failed; the app has not been removed.');
  if(statSync(destination).size<1024)throw Error('Backup is incomplete; the app has not been removed.');
  const hash=createHash('sha256');for await(const chunk of createReadStream(destination))hash.update(chunk);
  writeFileSync(destination+'.sha256',hash.digest('hex')+'\n');
}
async function verifyArchive(source){
  const child=spawn(adb,['shell','-T','run-as',pkg,'tar','-tf','-'],{stdio:['pipe','ignore','inherit']});
  const closed=once(child,'close');await pipeline(createReadStream(source),child.stdin);
  const [code]=await closed;if(code!==0)throw Error('Backup archive could not be verified; the old app has not been removed.');
}
async function restore(source){
  const child=spawn(adb,['shell','-T','run-as',pkg,'tar','-xf','-'],{stdio:['pipe','inherit','inherit']});
  const closed=once(child,'close');await pipeline(createReadStream(source),child.stdin);
  const [code]=await closed;if(code!==0)throw Error('Restore failed. Your backup remains available; do not delete it.');
}
try{
  if(!apk||!existsSync(apk))throw Error('Usage: node migrate-preview.mjs <path-to-dev8.apk> [backup-directory]');
  run(['get-state']);run(['shell','run-as',pkg,'pwd']);run(['shell','am','force-stop',pkg]);
  const directory=resolve(process.argv[3]||'capyflow-backups');mkdirSync(directory,{recursive:true});
  const archive=join(directory,`capyflow-${new Date().toISOString().replace(/[:.]/g,'-')}.tar`);
  console.log('Backing up playlists, artwork, account preferences and downloaded audio…');
  await backup(archive);await verifyArchive(archive);console.log(`Backup saved: ${archive}`);
  const attempt=run(['install','-r',apk],true);
  if(attempt.status===0){console.log('Updated successfully. Existing data was retained.');process.exit(0);}
  if(!attempt.output.includes('INSTALL_FAILED_UPDATE_INCOMPATIBLE'))throw Error(attempt.output);
  const prompt=createInterface({input:process.stdin,output:process.stdout});
  const answer=await prompt.question('The signing key changed. Replace the old preview and restore this backup? Type MIGRATE to continue: ');prompt.close();
  if(answer!=='MIGRATE'){console.log('Cancelled. The old app and backup are intact.');process.exit(0);}
  run(['uninstall',pkg]);run(['install',apk]);await restore(archive);
  console.log('Migration complete. Playlists, artwork and downloads were restored. Keep the backup until you have checked the app.');
}catch(e){console.error(e.message);process.exitCode=1;}
