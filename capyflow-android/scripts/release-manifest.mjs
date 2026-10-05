import {readFile,writeFile,copyFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {pathToFileURL} from 'node:url';
export function releaseMetadata(gradle,apk,notes=''){
 const code=Number(gradle.match(/versionCode\s*=\s*(\d+)/)?.[1]);const name=gradle.match(/versionName\s*=\s*"([^"]+)"/)?.[1];
 if(!Number.isSafeInteger(code)||code<1||!name||apk.length<1024)throw Error('Missing version or invalid APK');
 return {releaseNotes:notes.trim().slice(0,6000),versionCode:code,versionName:name,sha256:createHash('sha256').update(apk).digest('hex'),apkURL:`https://github.com/sephirothkazuhakaede-hash/LastWave-Native/releases/download/android-dev${code}/CapyFlow.apk`};
}
if(process.argv[1] && import.meta.url===pathToFileURL(process.argv[1]).href){
 const [apk,gradle,out,notes]=process.argv.slice(2);const data=releaseMetadata(await readFile(gradle,'utf8'),await readFile(apk),notes ? await readFile(notes,'utf8') : '');
 await copyFile(apk,`${out}/CapyFlow.apk`);await writeFile(`${out}/android-update.json`,JSON.stringify(data,null,2)+'\n');
}
