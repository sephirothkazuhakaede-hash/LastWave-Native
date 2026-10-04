import {initializeApp} from 'firebase-admin/app';
import {getFirestore} from 'firebase-admin/firestore';
import {getMessaging} from 'firebase-admin/messaging';
import {onDocumentCreated} from 'firebase-functions/v2/firestore';
import {notificationPlan} from './notification-plan.mjs';
initializeApp();
// Only trusted server code can send push. Client apps never receive server credentials.
export const messagePush = onDocumentCreated({document:'conversations/{threadID}/messages/{messageID}',region:'asia-southeast1'},async event => {
  const message=event.data?.data();if(!message)return;
  const db=getFirestore();const thread=(await db.doc(`conversations/${event.params.threadID}`).get()).data();
  const recipient=thread?.memberIDs?.find(id=>id!==message.senderID);
  const plan=notificationPlan(thread,{...message,id:event.params.messageID},recipient,thread?.readMessageIDs?.[recipient]);if(!plan)return;
  const devices=await db.collection(`users/${recipient}/devices`).get();
  const profile=(await db.doc(`profiles/${message.senderID}`).get()).data();
  const title=profile?.username ? `@${profile.username}` : 'CapyFlow listener';
  // Data-only delivery: Android verifies the active UID before showing private content.
  const targets=devices.docs.filter(d=>d.get('platform')==='android' && typeof d.get('token')==='string');
  for(let start=0;start<targets.length;start+=500){const batch=targets.slice(start,start+500);
    const result=await getMessaging().sendEachForMulticast({tokens:batch.map(d=>d.get('token')),data:{...plan,title},android:{priority:'high',ttl:86400000,collapseKey:event.params.threadID}});
    await Promise.all(result.responses.map((r,i)=>['messaging/registration-token-not-registered','messaging/invalid-registration-token'].includes(r.error?.code) ? batch[i].ref.delete() : Promise.resolve()));
  }
});
