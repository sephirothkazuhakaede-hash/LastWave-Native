import test from 'node:test';
import assert from 'node:assert/strict';
import {globalPushPlan,deliverGlobalPush} from '../src/global-push-core.js';
const now=1000000,message={senderID:'author',text:'Hello',createdAt:{toMillis:()=>now}};
const device={uid:'reader',token:'token',platform:'android'};
test('Global push targets only opted-in devices, skips author and duplicates',()=>{
 assert.equal(globalPushPlan('id',message,[],now).length,0);
 assert.deepEqual(globalPushPlan('id',message,[device,device,{...device,uid:'author'},{...device,platform:'ios'}],now).map(j=>j.data.recipientID),['reader']);
 assert.equal(globalPushPlan('id',message,[device],now+120001).length,0);
});
test('Accepted global deliveries are not replayed; failures can retry',async()=>{
 const accepted=new Set();let count=0;
 const state={accepted:(_,id,hash)=>accepted.has(id+hash),accept:async(_,id,hash)=>accepted.add(id+hash)};
 const args={id:'id',message,devices:[device],state,now,send:async()=>{count++}};
 await deliverGlobalPush(args);await deliverGlobalPush(args);assert.equal(count,1);
 await assert.rejects(deliverGlobalPush({...args,id:'other',send:async()=>{throw new Error('offline')}}));
 await deliverGlobalPush({...args,id:'other'});assert.equal(count,2);
});
