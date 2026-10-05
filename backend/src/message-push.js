import {readFile} from 'node:fs/promises';
import {MessagePushDispatcher} from './message-push-core.js';
import {MessagePushState} from './message-push-state.js';
export async function startMessagePush(config,logger=console){
  if(!config.pushEnabled)return {close:async()=>{}};
  if(!config.firebaseProjectId)throw new Error('FIREBASE_PROJECT_ID is required for message push.');
  const {initializeApp,applicationDefault,cert,deleteApp}=await import('firebase-admin/app');
  const {getFirestore,Timestamp}=await import('firebase-admin/firestore');
  const {getMessaging}=await import('firebase-admin/messaging');
  let credential=applicationDefault();
  if(config.pushCredentials){
    const json=JSON.parse(await readFile(config.pushCredentials,'utf8'));
    if(json.type!=='service_account' || json.project_id!==config.firebaseProjectId)throw new Error('Message push credentials belong to another project.');
    credential=cert(json);
  }
  const app=initializeApp({credential,projectId:config.firebaseProjectId},'capyflow-message-push');
  const db=getFirestore(app),messaging=getMessaging(app);
  const state=new MessagePushState(config.pushStateFile);await state.init();
  const dispatcher=new MessagePushDispatcher({
    state,logger,
    loadThread:async id=>(await db.doc('conversations/'+id).get()).data(),
    loadMessage:async(thread,id)=>(await db.doc('conversations/'+thread+'/messages/'+id).get()).data(),
    loadDevices:async uid=>(await db.collection('users/'+uid+'/devices').get()).docs.map(d=>d.data()),
    loadUsername:async uid=>(await db.doc('profiles/'+uid).get()).get('username'),
    send:(tokens,data,thread)=>messaging.sendEachForMulticast({tokens,data,android:{priority:'high',ttl:86400000,collapseKey:thread}})
  });
  // A rolling 24-hour query supports reconnect catch-up and uses a normal single-field index.
  let unsubscribe=()=>{},stopped=false,watchTimer;
  const watch=()=>{
    if(stopped)return;unsubscribe();
    unsubscribe=db.collection('conversations').where('updatedAt','>=',Timestamp.fromMillis(Date.now()-86400000)).onSnapshot(snapshot=>{
      for(const change of snapshot.docChanges())if(change.type!=='removed')void dispatcher.enqueue(change.doc.id);
    },error=>{
      logger.warn('Message push listener disconnected ('+(typeof error.code==='string'?error.code:'connection failure')+'); reconnecting.');
      clearTimeout(watchTimer);watchTimer=setTimeout(watch,30000);watchTimer.unref();
    });
  };
  watch();
  const retry=setInterval(()=>void dispatcher.retry(),60000);retry.unref();
  const refresh=setInterval(watch,3600000);refresh.unref();
  logger.info('Message push worker started; waiting for Firebase conversations.');
  return {close:async()=>{stopped=true;clearTimeout(watchTimer);clearInterval(retry);clearInterval(refresh);unsubscribe();await dispatcher.close();await deleteApp(app);}};
}
