import {tokenKey} from './message-push-core.js';

export function globalPushPlan(id,message,devices,now=Date.now()) {
  const created=message?.createdAt?.toMillis?.();
  if(typeof id!=='string' || typeof message?.senderID!=='string' || typeof message?.text!=='string' || !message.text.trim() || !Number.isFinite(created) || now-created>120000 || created>now+10000)return [];
  const seen=new Set();
  return devices.filter(device=>{
    if(device.platform!=='android' || typeof device.uid!=='string' || device.uid===message.senderID || typeof device.token!=='string' || !device.token || seen.has(device.token))return false;
    seen.add(device.token);return true;
  }).map(device=>({token:device.token,data:{kind:'global',recipientID:device.uid,senderID:message.senderID,messageID:id,title:'Global Chat',body:message.text.slice(0,300)}}));
}

export async function deliverGlobalPush({id,message,devices,state,send,now}) {
  const jobs=globalPushPlan(id,message,devices,now);
  for(const job of jobs){
    const hash=tokenKey(job.token);
    if(state.accepted('global',id,hash))continue;
    try {
      await send(job.token,job.data);
      await state.accept('global',id,hash);
    } catch(error) {
      if(['messaging/registration-token-not-registered','messaging/invalid-registration-token'].includes(error.code))await state.accept('global',id,hash);
      else throw error;
    }
  }
}
