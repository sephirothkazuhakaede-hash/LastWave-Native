import {readFile,writeFile,rename,mkdir} from 'node:fs/promises';
import path from 'node:path';
import {tokenKey} from './message-push-core.js';
export class MessagePushState{
  #entries=new Map();#writes=Promise.resolve();
  constructor(file){this.file=file;}
  async init(){
    try{const json=JSON.parse(await readFile(this.file,'utf8'));if(json.version!==1 || !Array.isArray(json.entries) || !json.entries.every(e=>Array.isArray(e) && typeof e[0]==='string' && Array.isArray(e[1]?.tokens) && e[1].tokens.every(t=>typeof t==='string')))throw new Error('Invalid state');this.#entries=new Map(json.entries.slice(-5000));}
    catch(e){if(e.code!=='ENOENT')throw new Error('Message push state cannot be read. Restore it before restarting.');}
  }
  #key(thread,id){return tokenKey(thread+':'+id);}
  completed(thread,id){return this.#entries.get(this.#key(thread,id))?.done===true;}
  accepted(thread,id,token){return this.#entries.get(this.#key(thread,id))?.tokens?.includes(token)===true;}
  async accept(thread,id,token){const key=this.#key(thread,id),old=this.#entries.get(key) ?? {tokens:[],done:false};if(!old.tokens.includes(token))old.tokens.push(token);this.#entries.set(key,old);await this.#save();}
  async complete(thread,id){const key=this.#key(thread,id),old=this.#entries.get(key) ?? {tokens:[]};this.#entries.set(key,{...old,done:true});await this.#save();}
  #save(){
    while(this.#entries.size>5000)this.#entries.delete(this.#entries.keys().next().value);
    const data=JSON.stringify({version:1,entries:[...this.#entries]});
    const job=this.#writes.then(async()=>{await mkdir(path.dirname(this.file),{recursive:true});await writeFile(this.file+'.tmp',data,{mode:0o600});await rename(this.file+'.tmp',this.file);});
    this.#writes=job.catch(()=>{});return job;
  }
}
