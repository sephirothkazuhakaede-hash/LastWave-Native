import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,rm,readFile} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {MessagePushDispatcher,messagePlan} from '../src/message-push-core.js';
import {MessagePushState} from '../src/message-push-state.js';
const thread=()=>({memberIDs:['alice','bob'],lastMessageID:'m1',lastSenderID:'alice',readMessageIDs:{alice:'m1',bob:''}});
const message=()=>({senderID:'alice',text:'Hello'});
async function fixture(t,{devices=[{platform:'android',token:'private-token'}],send,beforeDevices}={}){
 const dir=await mkdtemp(path.join(os.tmpdir(),'capyflow-push-'));t.after(()=>rm(dir,{recursive:true,force:true}));
 const state=new MessagePushState(path.join(dir,'state.json'));await state.init();let current=thread(),calls=0;
 const dispatcher=new MessagePushDispatcher({state,logger:{info(){},warn(){}},loadThread:async()=>current,loadMessage:async()=>message(),loadDevices:async()=>{beforeDevices?.();return devices;},loadUsername:async()=>'seph',send:async(...args)=>{calls++;return send?send(...args):{responses:args[0].map(()=>({success:true}))};}});
 t.after(()=>dispatcher.close());
 return {state,dispatcher,dir,calls:()=>calls,setThread:value=>{current=value;}};
}
test('sender cannot push to itself, outsiders, or an already-read message',()=>{
 const d=thread();assert.equal(messagePlan(d,message(),'m1').recipientID,'bob');
 assert.equal(messagePlan(d,{senderID:'mallory',text:'Fake'},'m1'),null);
 assert.equal(messagePlan({...d,readMessageIDs:{bob:'m1'}},message(),'m1'),null);
 assert.equal(messagePlan({...d,memberIDs:['alice','alice']},message(),'m1'),null);
 assert.equal(messagePlan(d,message(),'old'),null);
});
test('repeated Firestore events and restart do not resend accepted notifications',async t=>{
 const f=await fixture(t);await Promise.all([f.dispatcher.enqueue('alice_bob'),f.dispatcher.enqueue('alice_bob')]);assert.equal(f.calls(),1);
 const restored=new MessagePushState(path.join(f.dir,'state.json'));await restored.init();assert.equal(restored.completed('alice_bob','m1'),true);
 const data=await readFile(path.join(f.dir,'state.json'),'utf8');assert.equal(data.includes('private-token'),false);assert.equal(data.includes('alice_bob'),false);
});
test('partial FCM failure retries only the token not accepted yet',async t=>{
 let calls=0;
 const f=await fixture(t,{devices:[{platform:'android',token:'one'},{platform:'android',token:'two'}],send:async tokens=>{
   calls++;if(calls===1)return {responses:[{success:true},{success:false,error:{code:'messaging/unavailable'}}]};
   assert.deepEqual(tokens,['two']);return {responses:[{success:true}]};
 }});
 await f.dispatcher.enqueue('alice_bob');assert.equal(f.state.completed('alice_bob','m1'),false);
 await f.dispatcher.retry();assert.equal(f.state.completed('alice_bob','m1'),true);assert.equal(calls,2);
});
test('a message read during device lookup is not pushed',async t=>{
 let f;f=await fixture(t,{beforeDevices:()=>f.setThread({...thread(),readMessageIDs:{bob:'m1'}}),send:async()=>{throw Error('must not send');}});
 await f.dispatcher.enqueue('alice_bob');assert.equal(f.calls(),0);
});
test('device registered after sending receives a pending unread notification',async t=>{
 const devices=[];const f=await fixture(t,{devices});await f.dispatcher.enqueue('alice_bob');assert.equal(f.calls(),0);
 devices.push({platform:'android',token:'later'});await f.dispatcher.retry();assert.equal(f.calls(),1);
});
test('invalid tokens do not cause endless retries and iOS tokens are not sent as Android',async t=>{
 const f=await fixture(t,{devices:[{platform:'android',token:'bad'},{platform:'ios',token:'apns'}],send:async tokens=>{assert.deepEqual(tokens,['bad']);return{responses:[{success:false,error:{code:'messaging/registration-token-not-registered'}}]};}});
 await f.dispatcher.enqueue('alice_bob');await f.dispatcher.retry();assert.equal(f.calls(),1);
});
test('closing the worker stops new notifications',async t=>{
 const f=await fixture(t);await f.dispatcher.close();await f.dispatcher.enqueue('alice_bob');assert.equal(f.calls(),0);
});
