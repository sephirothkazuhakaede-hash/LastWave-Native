package com.seph.capyflow

import androidx.compose.runtime.*
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.google.firebase.firestore.*
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await
import java.util.UUID

data class Profile(val id: String, val username: String, val displayName: String, val bio: String, val avatar: String?) {
    companion object { fun from(d: DocumentSnapshot) = Profile(d.id, d.getString("username") ?: "", d.getString("displayName") ?: d.getString("username") ?: "CapyFlow listener", d.getString("bio") ?: "", d.getString("avatarURL")) }
}
data class Conversation(val id: String, val peer: String, val text: String, val unread: Boolean, val date: Long)
data class Message(val id: String, val sender: String, val text: String, val pending: Boolean)
class SocialModel : ViewModel() {
    var profiles by mutableStateOf<List<Profile>>(emptyList()); private set
    var following by mutableStateOf<Set<String>>(emptySet()); private set
    var inbox by mutableStateOf<List<Conversation>>(emptyList()); private set
    var messages by mutableStateOf<List<Message>>(emptyList()); private set
    var error by mutableStateOf<String?>(null)
    var sending by mutableStateOf(false); private set
    var searching by mutableStateOf(false); private set
    private var db: FirebaseFirestore? = null
    private var uid: String? = null
    private var peer: String? = null
    private var thread: DocumentReference? = null
    private var lastMessageID: String? = null
    private var threadExists = false
    private var ownReadID: String? = null
    private var readingID: String? = null
    private val listeners = mutableListOf<ListenerRegistration>()
    private var chatListener: ListenerRegistration? = null
    private var threadListener: ListenerRegistration? = null
    private var generation = 0
    fun bind(database: FirebaseFirestore?, userID: String?) {
        if(db === database && uid == userID) return
        generation++; listeners.forEach { it.remove() }; listeners.clear(); closeChat(); db = database; uid = userID
        following = emptySet(); inbox = emptyList(); profiles = emptyList()
        if(database == null || userID == null) return
        val epoch = generation
        listeners += database.collection("follows").whereEqualTo("followerID", userID).addSnapshotListener { s,e ->
            if(epoch != generation) return@addSnapshotListener
            if(e != null) error = e.message
            if(s != null) following = s.documents.mapNotNull { it.getString("followingID") }.toSet()
        }
        listeners += database.collection("conversations").whereArrayContains("memberIDs", userID).limit(50).addSnapshotListener { s,e ->
            if(epoch != generation) return@addSnapshotListener
            if(e != null) error = e.message
            if(s != null) inbox = s.documents.mapNotNull { d ->
                val members = (d.get("memberIDs") as? List<*>)?.filterIsInstance<String>() ?: return@mapNotNull null
                val p = members.firstOrNull { it != userID } ?: return@mapNotNull null
                val reads = d.get("readMessageIDs") as? Map<*,*>
                Conversation(d.id,p,d.getString("lastText") ?: "",d.getString("lastSenderID") != userID && reads?.get(userID) != d.getString("lastMessageID"),d.getTimestamp("updatedAt")?.toDate()?.time ?: 0)
            }.sortedByDescending { it.date }
        }
    }
    fun findPeople(raw: String) {
        val database = db ?: return; val query = raw.trim().removePrefix("@").lowercase(); if(query.isBlank()) return
        val epoch = generation
        viewModelScope.launch { searching = true
            try { val docs = database.collection("profiles").orderBy("username").startAt(query).endAt(query + "\uf8ff").limit(20).get().await(); if(epoch == generation) profiles = docs.documents.map { Profile.from(it) } }
            catch(e: Exception) { if(epoch == generation) error = e.message } finally { if(epoch == generation) searching = false }
        }
    }
    fun follow(profile: Profile, value: Boolean) {
        val userID = uid ?: return; val ref = db?.collection("follows")?.document(userID + "_" + profile.id) ?: return
        if(profile.id == userID) return
        val task = if(value) ref.set(mapOf("followerID" to userID,"followingID" to profile.id,"createdAt" to FieldValue.serverTimestamp())) else ref.delete()
        task.addOnFailureListener { error = it.message }
    }
    suspend fun profile(id: String): Profile? = db?.collection("profiles")?.document(id)?.get()?.await()?.let { if(it.exists()) Profile.from(it) else null }
    fun openChat(peerID: String) {
        closeChat(); val userID = uid ?: return; if(userID == peerID) return
        peer = peerID; thread = db!!.collection("conversations").document(conversationID(userID,peerID))
        val ref = thread!!
        threadListener = ref.addSnapshotListener { s,e ->
            if(thread != ref) return@addSnapshotListener
            if(e != null) { error = e.message; return@addSnapshotListener }
            threadExists = s?.exists() == true
            lastMessageID = s?.getString("lastMessageID")
            ownReadID = (s?.get("readMessageIDs") as? Map<*, *>)?.get(userID) as? String
            if(threadExists && chatListener == null) chatListener = ref.collection("messages").orderBy("createdAt",Query.Direction.DESCENDING).limit(50).addSnapshotListener(MetadataChanges.INCLUDE) { ms, failure ->
                if(thread != ref) return@addSnapshotListener
                if(failure != null) error = failure.message
                if(ms != null) { messages = ms.documents.reversed().map { Message(it.id,it.getString("senderID") ?: "",it.getString("text") ?: "",it.metadata.hasPendingWrites()) }; markRead() }
            }
            markRead()
        }
    }
    private fun markRead() {
        val id = lastMessageID ?: return; val userID = uid ?: return
        if(ownReadID == id || readingID == id) return
        if(messages.any { it.id == id && it.sender != userID }) {
            readingID = id
            thread?.update("readMessageIDs.$userID",id)?.addOnFailureListener { readingID = null; error = it.message }
        }
    }
    fun send(raw: String, onSuccess: () -> Unit) {
        val text = raw.trim(); if(sending || text.isEmpty() || text.length > 4000) return
        val userID = uid ?: return; val peerID = peer ?: return; val ref = thread ?: return; val database = db ?: return
        val batch = database.batch(); val id = UUID.randomUUID().toString(); val time = FieldValue.serverTimestamp()
        batch.set(ref.collection("messages").document(id),mapOf("senderID" to userID,"text" to text,"createdAt" to time))
        if(threadExists) batch.update(ref,mapOf("lastMessageID" to id,"lastText" to text,"lastSenderID" to userID,"updatedAt" to time,"readMessageIDs.$userID" to id))
        else batch.set(ref,mapOf("memberIDs" to listOf(userID,peerID).sorted(),"lastMessageID" to id,"lastText" to text,"lastSenderID" to userID,"createdAt" to time,"updatedAt" to time,"readMessageIDs" to mapOf(userID to id,peerID to "")))
        sending = true; error = null
        batch.commit().addOnSuccessListener { if(thread == ref) { sending = false; onSuccess() } }.addOnFailureListener { if(thread == ref) { sending = false; error = it.message } }
    }
    fun closeChat() { chatListener?.remove(); threadListener?.remove(); chatListener = null; threadListener = null; thread = null; peer = null; messages = emptyList(); lastMessageID = null; ownReadID = null; readingID = null; threadExists = false; sending = false }
    override fun onCleared() { listeners.forEach { it.remove() }; closeChat() }
    companion object { fun conversationID(a: String,b: String) = listOf(a,b).sorted().joinToString("_") }
}
