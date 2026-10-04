export function notificationPlan(thread, message, recipient, readID) {
  if (!thread || !message || !Array.isArray(thread.memberIDs) || thread.memberIDs.length !== 2) return null;
  if (!thread.memberIDs.includes(message.senderID) || !thread.memberIDs.includes(recipient) || recipient === message.senderID || readID === message.id) return null;
  if (typeof message.text !== 'string' || !message.text.trim()) return null;
  return {recipientID:recipient, senderID:message.senderID, body:message.text.slice(0,300), title:'New CapyFlow message', messageID:message.id};
}
