import {createHash} from 'node:crypto';
import {readFile} from 'node:fs/promises';
const gradle=await readFile('capyflow-android/app/build.gradle.kts','utf8');
const code=Number(gradle.match(/versionCode\s*=\s*(\d+)/)?.[1]);
const name=gradle.match(/versionName\s*=\s*"([^"]+)"/)?.[1];
const prefix='https://github.com/sephirothkazuhakaede-hash/LastWave-Native/releases/download/android-dev'+code+'/';
const fetchBytes=async url=>{const r=await fetch(url,{signal:AbortSignal.timeout(60000)});if(!r.ok)throw Error('Public update request returned '+r.status);return Buffer.from(await r.arrayBuffer());};
const manifest=JSON.parse((await fetchBytes(prefix+'android-update.json')).toString());
if(manifest.versionCode!==code || manifest.versionName!==name || manifest.apkURL!==prefix+'CapyFlow.apk' || !manifest.releaseNotes?.trim())throw Error('Incompatible dev9 update metadata');
const apk=await fetchBytes(manifest.apkURL);
if(createHash('sha256').update(apk).digest('hex')!==manifest.sha256)throw Error('Public APK checksum mismatch');
const eocd=apk.lastIndexOf(Buffer.from([0x50,0x4b,0x05,0x06]));if(eocd<0)throw Error('Invalid APK ZIP');
const cd=apk.readUInt32LE(eocd+16);if(apk.subarray(cd-16,cd).toString()!=='APK Sig Block 42')throw Error('APK signing block missing');
const size=Number(apk.readBigUInt64LE(cd-24));let pos=cd-size,signer;
const lp=(b,o=0)=>{const n=b.readUInt32LE(o);return [b.subarray(o+4,o+4+n),o+4+n];};
while(pos<cd-24){const length=Number(apk.readBigUInt64LE(pos)),id=apk.readUInt32LE(pos+8);if(id===0x7109871a){
 const [signers]=lp(apk.subarray(pos+12,pos+8+length)),[one]=lp(signers),[signed]=lp(one),[,offset]=lp(signed),[certs]=lp(signed,offset),[cert]=lp(certs);
 signer=createHash('sha1').update(cert).digest('hex');
}pos+=8+length;}
const expected=(await readFile('.github/capyflow-signing-sha1.txt','utf8')).replace(/[^a-f0-9]/gi,'').toLowerCase();
if(signer!==expected)throw Error('APK certificate does not match dev8/dev9');
console.log('Public Android update manifest, release notes, APK checksum and dev9-compatible certificate verified.');
