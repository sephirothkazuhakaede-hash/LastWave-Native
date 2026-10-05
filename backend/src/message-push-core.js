import crypto from 'node:crypto';
export const tokenKey = value => crypto.createHash('sha256').update(value).digest('hex');
export function messagePlan(thread,message,id){
  if(!thread || !message || !Array.isArray(thread.memberIDs) || thread.memberIDs.length!==2 || !thread.memberIDs.every(x=>typeof x==='string') || thread.memberIDs[0]===thread.memberIDs[1])return null;
  if(thread.lastMessageID!==id || thread.lastSenderID!==message.senderID || !thread.memberIDs.includes(message.senderID) || typeof message.text!=='string' || !message.text.trim())return null;
  const recipient=thread.memberIDs.find(x=>x!==message.senderID);
  if(thread.readMessageIDs?.[recipient]===id)return null;
  return {recipientID:recipient,senderID:message.senderID,messageID:id,body:message.text.slice(0,300)};
}
export class MessagePushDispatcher {
  #jobs=new Map();#pending=new Set();#stopped=false;
  constructor({loadThread,loadMessage,loadDevices,loadUsername,send,state,logger=console}){Object.assign(this,{loadThread,loadMessage,loadDevices,loadUsername,send,state,logger});}
  enqueue(id){
    if(this.#stopped)return Promise.resolve();
    const previous=this.#jobs.get(id) ?? Promise.resolve();
    const job=previous.then(()=>this.#handle(id)).catch(error=>{
      if(this.#pending.size<500)this.#pending.add(id);
      this.logger.warn('Message push will retry ('+(typeof error?.code==='string'?error.code:'temporary failure')+').');
    }).finally(()=>{if(this.#jobs.get(id)===job)this.#jobs.delete(id);});
    this.#jobs.set(id,job);return job;
  }
  retry(){return Promise.all([...this.#pending].map(id=>this.enqueue(id)));}
  async close(){this.#stopped=true;await Promise.allSettled(this.#jobs.values());}
  async #handle(threadID){
    if(this.#stopped)return;
    const thread=await this.loadThread(threadID),id=thread?.lastMessageID;
    if(!id || this.state.completed(threadID,id)){this.#pending.delete(threadID);return;}
    const message=await this.loadMessage(threadID,id);
    const plan=messagePlan(thread,message,id);
    if(!plan){this.#pending.delete(threadID);return;}
    const targets=(await this.loadDevices(plan.recipientID)).filter(d=>d.platform==='android' && typeof d.token==='string' && d.token.length>0 && d.token.length<=4096);
    const unique=[...new Map(targets.map(d=>[d.token,d])).values()];
    if(!unique.length){if(this.#pending.size<500)this.#pending.add(threadID);return;}
    const unsent=unique.filter(d=>!this.state.accepted(threadID,id,tokenKey(d.token)));
    const username=await this.loadUsername(plan.senderID);
    for(let offset=0;offset<unsent.length;offset+=500){
      // Re-check read state immediately before sending; never trust a public HTTP request.
      const fresh=await this.loadThread(threadID);
      if(!messagePlan(fresh,message,id)){this.#pending.delete(threadID);return;}
      const batch=unsent.slice(offset,offset+500);
      const result=await this.send(batch.map(d=>d.token),{...plan,title:typeof username==='string' && username.length?'@'+username.slice(0,100):'CapyFlow listener'},threadID);
      for(let i=0;i<batch.length;i++){
        const r=result.responses[i];
        if(r?.success || ['messaging/registration-token-not-registered','messaging/invalid-registration-token'].includes(r?.error?.code))
          await this.state.accept(threadID,id,tokenKey(batch[i].token));
      }
    }
    if(unique.every(d=>this.state.accepted(threadID,id,tokenKey(d.token)))){
      await this.state.complete(threadID,id);this.#pending.delete(threadID);
      this.logger.info('Message notification processed.');
    }else if(this.#pending.size<500)this.#pending.add(threadID);
  }
}
