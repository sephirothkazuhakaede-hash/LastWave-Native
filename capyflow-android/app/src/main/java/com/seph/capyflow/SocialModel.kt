package com.seph.capyflow

import androidx.compose.runtime.*
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.google.firebase.firestore.*
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await
import java.util.UUID
import org.json.JSONObject
import com.google.firebase.Timestamp

data class Profile(val id: String, val username: String, val displayName: String, val bio: String, val avatar: String?, val avatarData: ByteArray? = null) {
    companion object { fun from(d: DocumentSnapshot) = Profile(d.id, d.getString("username") ?: "", d.getString("displayName") ?: d.getString("username") ?: "CapyFlow listener", d.getString("bio") ?: "", d.getString("avatarURL"),d.getBlob("avatarData")?.toBytes()) }
}
data class Conversation(val id: String, val peer: String, val text: String, val unread: Boolean, val date: Long)
data class Message(val id: String, val sender: String, val text: String, val pending: Boolean, val date: Long = 0)
class SocialModel : ViewModel() {
    var ownProfile by mutableStateOf<Profile?>(null); private set
    var sharedPlaylists by mutableStateOf<List<SharedCollection>>(emptyList()); private set
    var sharingActivity by mutableStateOf(false); private set
    var activity by mutableStateOf<Map<String,ListeningActivity>>(emptyMap()); private set
    var peerReadID by mutableStateOf<String?>(null); private set
    var peerDeliveredID by mutableStateOf<String?>(null); private set
    var savingProfile by mutableStateOf(false); private set
    private val friendListeners = mutableMapOf<String,List<ListenerRegistration>>()
    var friends by mutableStateOf<Map<String,Profile>>(emptyMap()); private set
    private var receiptListener: ListenerRegistration? = null
    private var acknowledged = mutableMapOf<String,String>()
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
        following = emptySet(); inbox = emptyList(); profiles = emptyList(); savingProfile=false;searching=false;error=null;ownProfile=null; sharedPlaylists=emptyList(); activity=emptyMap(); friends=emptyMap(); sharingActivity=false
        friendListeners.values.flatten().forEach{it.remove()};friendListeners.clear();acknowledged.clear()
        if(database == null || userID == null) return
        val epoch = generation
        ensureProfile(userID)
        listeners += database.collection("profiles").document(userID).addSnapshotListener { d,e ->
            if(epoch==generation){if(e!=null)error=e.message;ownProfile=d?.takeIf{it.exists()}?.let{Profile.from(it)};syncCreatorUsernames()}
        }
        listeners += database.collection("playlists").whereArrayContains("memberIDs",userID).addSnapshotListener { s,e ->
            if(epoch==generation){if(e!=null)error=e.message;if(s!=null)sharedPlaylists=s.documents.mapNotNull{SharedCollection.from(it)};syncCreatorUsernames()}
        }
        listeners += database.collection("activitySettings").document(userID).addSnapshotListener { d,e ->
            if(epoch==generation){if(e!=null)error=e.message;sharingActivity=d?.getBoolean("sharing")==true}
        }
        listeners += database.collection("follows").whereEqualTo("followerID", userID).addSnapshotListener { s,e ->
            if(epoch != generation) return@addSnapshotListener
            if(e != null) error = e.message
            if(s != null) {following = s.documents.mapNotNull { it.getString("followingID") }.toSet();observeFriends(epoch)}
        }
        listeners += database.collection("conversations").whereArrayContains("memberIDs", userID).limit(50).addSnapshotListener { s,e ->
            if(epoch != generation) return@addSnapshotListener
            if(e != null) error = e.message
            if(s != null) { inbox = s.documents.mapNotNull { d ->
                val members = (d.get("memberIDs") as? List<*>)?.filterIsInstance<String>() ?: return@mapNotNull null
                val p = members.firstOrNull { it != userID } ?: return@mapNotNull null
                val reads = d.get("readMessageIDs") as? Map<*,*>
                Conversation(d.id,p,d.getString("lastText") ?: "",d.getString("lastSenderID") != userID && reads?.get(userID) != d.getString("lastMessageID"),d.getTimestamp("updatedAt")?.toDate()?.time ?: 0)
            }.sortedByDescending { it.date }
                if(!s.metadata.isFromCache) s.documents.forEach{d -> acknowledge(d)}
            }
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
            peerReadID=(s?.get("readMessageIDs") as? Map<*, *>)?.get(peerID) as? String
            if(threadExists && receiptListener==null)receiptListener=ref.collection("receipts").document(peerID).addSnapshotListener{d,failure -> if(thread==ref){if(failure!=null)error=failure.message;peerDeliveredID=d?.getString("messageID")}}
            if(s!=null && !s.metadata.isFromCache)acknowledge(s)
            if(threadExists && chatListener == null) chatListener = ref.collection("messages").orderBy("createdAt",Query.Direction.DESCENDING).limit(50).addSnapshotListener(MetadataChanges.INCLUDE) { ms, failure ->
                if(thread != ref) return@addSnapshotListener
                if(failure != null) error = failure.message
                if(ms != null) { messages = ms.documents.reversed().map { Message(it.id,it.getString("senderID") ?: "",it.getString("text") ?: "",it.metadata.hasPendingWrites(),it.getTimestamp("createdAt")?.toDate()?.time ?: 0) }; markRead() }
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
    fun closeChat() { receiptListener?.remove();receiptListener=null;peerReadID=null;peerDeliveredID=null; chatListener?.remove(); threadListener?.remove(); chatListener = null; threadListener = null; thread = null; peer = null; messages = emptyList(); lastMessageID = null; ownReadID = null; readingID = null; threadExists = false; sending = false }
    override fun onCleared() { listeners.forEach { it.remove() };friendListeners.values.flatten().forEach{it.remove()}; closeChat() }
    fun watchProfile(id: String,onChange:(Profile?)->Unit): ListenerRegistration? = db?.collection("profiles")?.document(id)?.addSnapshotListener{d,e -> if(e!=null)error=e.message;onChange(d?.takeIf{it.exists()}?.let{Profile.from(it)})}
    fun watchRelationships(id: String,followers: Boolean,onChange:(List<String>)->Unit): ListenerRegistration? = db?.collection("follows")?.whereEqualTo(if(followers)"followingID" else "followerID",id)?.addSnapshotListener{s,e -> if(e!=null)error=e.message;if(s!=null)onChange(s.documents.mapNotNull{it.getString(if(followers)"followerID" else "followingID")}.distinct())}
    private fun ensureProfile(userID: String){
        val database=db ?: return;val epoch=generation
        viewModelScope.launch{try{
            val ref=database.collection("profiles").document(userID)
            database.runTransaction{tx ->
                val existing=tx.get(ref)
                if(existing.exists())return@runTransaction null
                val generated="listener_"+UUID.randomUUID().toString().replace("-", "").take(10)
                val reservation=database.collection("usernames").document(generated)
                check(!tx.get(reservation).exists()){ "Couldn’t reserve a username. Please sign in again." }
                tx.set(reservation,mapOf("uid" to userID,"createdAt" to FieldValue.serverTimestamp()))
                tx.set(ref,mapOf("username" to generated,"usernameKey" to generated,"usernameIsGenerated" to true,"displayName" to "CapyFlow listener","bio" to "","avatarURL" to "","createdAt" to FieldValue.serverTimestamp(),"updatedAt" to FieldValue.serverTimestamp()))
                null
            }.await()
        }catch(e:Exception){if(epoch==generation)error=e.message}}
    }
    fun saveProfile(rawUsername: String,name: String,bio: String,photo: ByteArray?,onSaved:()->Unit){
        val database=db ?: return;val userID=uid ?: return
        val username=rawUsername.trim().removePrefix("@").lowercase();val display=name.trim()
        if(!UsernamePolicy.valid(username)){error="Use 3–20 lowercase letters, numbers, dots or underscores. Choose a non-reserved username.";return}
        if(display.isEmpty()||display.length>60||bio.length>160|| (photo?.size ?: 0)>131072){error="Name must be 1–60 characters, bio up to 160 characters, and photo up to 128 KB.";return}
        if(savingProfile)return
        val epoch=generation;savingProfile=true
        viewModelScope.launch{try{
            val ref=database.collection("profiles").document(userID);val reservation=database.collection("usernames").document(username)
            database.runTransaction{tx ->
                val existing=tx.get(ref);check(existing.exists()){ "Your profile is still loading." }
                val previous=existing.getString("username") ?: error("Missing profile username")
                val claimed=tx.get(reservation)
                check(!claimed.exists()||claimed.getString("uid")==userID){"That username is already taken."}
                val oldReservation=if(previous!=username)database.collection("usernames").document(previous) else null
                val old=oldReservation?.let{tx.get(it)}
                if(previous!=username && existing.getBoolean("usernameIsGenerated")!=true){
                    val changed=existing.getTimestamp("usernameChangedAt")?.toDate()?.time
                    check(changed==null || System.currentTimeMillis()-changed>=14L*86400000){"You can change your username once every 14 days."}
                }
                if(!claimed.exists())tx.set(reservation,mapOf("uid" to userID,"createdAt" to FieldValue.serverTimestamp()))
                val fields=mutableMapOf<String,Any>("username" to username,"usernameKey" to username,"displayName" to display,"bio" to bio,"updatedAt" to FieldValue.serverTimestamp())
                photo?.let{fields["avatarData"]=Blob.fromBytes(it);fields["avatarURL"]=""}
                if(previous!=username){fields["usernameIsGenerated"]=false;fields["usernameChangedAt"]=FieldValue.serverTimestamp()}
                tx.update(ref,fields)
                if(old?.getString("uid")==userID && oldReservation!=null)tx.delete(oldReservation)
                null
            }.await()
            if(epoch==generation)onSaved()
        }catch(e:Exception){if(epoch==generation)error=e.message}finally{if(epoch==generation)savingProfile=false}}
    }
    fun sharedFor(playlist: Playlist)=sharedPlaylists.firstOrNull{ "cloud:"+it.id==playlist.id || (it.ownerID==uid && it.sourceID==playlist.id)}
    suspend fun publish(playlist: Playlist): String {
        val database=db ?: error("Sign in to collaborate");val userID=uid ?: error("Sign in to collaborate")
        sharedFor(playlist)?.let{check(it.ownerID==userID){"Only the owner can invite collaborators"};return it.id}
        // Find iOS publications as well, avoiding a second shared copy of the source.
        val existing=database.collection("playlists").whereArrayContains("memberIDs",userID).get().await().documents.mapNotNull{SharedCollection.from(it)}.firstOrNull{it.sourceID==playlist.id && it.ownerID==userID}
        if(existing!=null)return existing.id
        val username=ownProfile?.username ?: error("Your profile is still loading")
        val id=UUID.nameUUIDFromBytes((userID+":"+playlist.id).toByteArray()).toString()
        database.collection("playlists").document(id).set(mapOf("sourceID" to playlist.id,"name" to playlist.name,"ownerID" to userID,"ownerName" to username,"memberIDs" to listOf(userID),"tracks" to playlist.tracks.map{jsonMap(it.json())},"createdAt" to FieldValue.serverTimestamp(),"updatedAt" to FieldValue.serverTimestamp())).await()
        return id
    }
    fun invite(sharedID:String,raw:String){
        val database=db ?: return;val userID=uid ?: return
        viewModelScope.launch{try{
            val ref=database.collection("playlists").document(sharedID)
            val person=database.collection("usernames").document(raw.trim().removePrefix("@").lowercase()).get().await().getString("uid") ?: error("No person found with that username")
            database.runTransaction{tx -> val d=tx.get(ref);check(d.getString("ownerID")==userID){"Only the owner can invite collaborators"};tx.update(ref,mapOf("memberIDs" to FieldValue.arrayUnion(person),"updatedAt" to FieldValue.serverTimestamp()));null}.await()
        }catch(e:Exception){error=e.message}}
    }
    fun removeMember(shared:SharedCollection,member:String){db?.collection("playlists")?.document(shared.id)?.update(mapOf("memberIDs" to FieldValue.arrayRemove(member),"updatedAt" to FieldValue.serverTimestamp()))?.addOnFailureListener{error=it.message}}
    fun editShared(shared:SharedCollection,change:(List<Track>)->List<Track>){
        val database=db ?: return;val userID=uid ?: return
        viewModelScope.launch{try{database.runTransaction{tx -> val ref=database.collection("playlists").document(shared.id);val d=tx.get(ref);check((d.get("memberIDs") as? List<*>)?.contains(userID)==true){"You are no longer a collaborator"};val current=SharedCollection.from(d) ?: error("Playlist unavailable");tx.update(ref,mapOf("tracks" to change(current.tracks).map{jsonMap(it.json())},"updatedAt" to FieldValue.serverTimestamp()));null}.await()}catch(e:Exception){error=e.message}}
    }
    fun renameShared(shared:SharedCollection,name:String){if(name.isNotBlank())db?.collection("playlists")?.document(shared.id)?.update(mapOf("name" to name.trim(),"updatedAt" to FieldValue.serverTimestamp()))?.addOnFailureListener{error=it.message}}
    fun deleteShared(shared:SharedCollection,onDeleted:()->Unit){db?.collection("playlists")?.document(shared.id)?.delete()?.addOnSuccessListener{onDeleted()}?.addOnFailureListener{error=it.message}}
    private fun syncCreatorUsernames(){
        val username=ownProfile?.username ?: return;val userID=uid ?: return
        sharedPlaylists.filter{it.ownerID==userID && it.ownerName!=username}.forEach{shared -> db?.collection("playlists")?.document(shared.id)?.update(mapOf("ownerName" to username,"updatedAt" to FieldValue.serverTimestamp()))?.addOnFailureListener{error=it.message}}
    }
    private fun observeFriends(epoch:Int){
        val database=db ?: return;val selected=following.take(50).toSet()
        friendListeners.keys.toList().filter{it !in selected}.forEach{id -> friendListeners.remove(id)?.forEach{it.remove()};friends=friends-id;activity=activity-id}
        selected.filter{it !in friendListeners}.forEach{id ->
            val p=database.collection("profiles").document(id).addSnapshotListener{d,_ -> if(epoch==generation){d?.takeIf{it.exists()}?.let{friends=friends+(id to Profile.from(it))}}}
            val a=database.collection("listeningActivity").document(id).addSnapshotListener{d,_ -> if(epoch==generation){val item=d?.let{ListeningActivity.from(it)};activity=if(item==null)activity-id else activity+(id to item)}}
            friendListeners[id]=listOf(p,a)
        }
    }
    fun setActivitySharing(enabled:Boolean){
        val database=db ?: return;val userID=uid ?: return
        val batch=database.batch();batch.set(database.collection("activitySettings").document(userID),mapOf("sharing" to enabled,"updatedAt" to FieldValue.serverTimestamp()))
        if(!enabled)batch.delete(database.collection("listeningActivity").document(userID))
        batch.commit().addOnFailureListener{error=it.message}
    }
    fun publishActivity(track:Track?,playing:Boolean){
        if(!sharingActivity)return;val database=db ?: return;val userID=uid ?: return
        val ref=database.collection("listeningActivity").document(userID)
        if(track==null){ref.delete();return}
        ref.set(mapOf("title" to track.title.take(300),"artist" to track.artist.take(300),"videoID" to track.playableID.take(128),"artworkURL" to Catalog.artworkForDisplay(track.artwork).take(2048),"playing" to playing,"updatedAt" to FieldValue.serverTimestamp(),"expiresAt" to Timestamp(java.util.Date(System.currentTimeMillis()+5*60000)))).addOnFailureListener{error=it.message}
    }
    private fun acknowledge(d:DocumentSnapshot){
        val userID=uid ?: return;val id=d.getString("lastMessageID") ?: return
        if(d.getString("lastSenderID")==userID || acknowledged[d.id]==id)return
        acknowledged[d.id]=id
        d.reference.collection("receipts").document(userID).set(mapOf("messageID" to id,"receivedAt" to FieldValue.serverTimestamp())).addOnFailureListener{if(acknowledged[d.id]==id)acknowledged.remove(d.id)}
    }
    fun messageStatus(message:Message):String{
        if(message.pending)return "Sending…"
        val index=messages.indexOfFirst{it.id==message.id}
        fun passed(id:String?)=id!=null && index>=0 && messages.indexOfFirst{it.id==id}>=index
        return when{passed(peerReadID)->"Seen";passed(peerDeliveredID)->"Delivered";else->"Sent"}
    }
    companion object { fun conversationID(a: String,b: String) = listOf(a,b).sorted().joinToString("_") }
}

data class SharedCollection(val id:String,val sourceID:String,val name:String,val ownerID:String,val ownerName:String,val memberIDs:List<String>,val tracks:List<Track>){
    fun imported()=Playlist("cloud:"+id,name,tracks,ownerID=ownerID)
    companion object{fun from(d:DocumentSnapshot):SharedCollection?{
        val name=d.getString("name") ?: return null;val owner=d.getString("ownerID") ?: return null
        val tracks=(d.get("tracks") as? List<*>)?.mapNotNull{runCatching{Track.from(JSONObject(it as Map<*,*>))}.getOrNull()}.orEmpty()
        return SharedCollection(d.id,d.getString("sourceID") ?: d.id,name,owner,d.getString("ownerName") ?: "",(d.get("memberIDs") as? List<*>)?.filterIsInstance<String>().orEmpty(),tracks)
    }}
}
data class ListeningActivity(val title:String,val artist:String,val artwork:String?,val playing:Boolean,val expires:Long){
    companion object{fun from(d:DocumentSnapshot):ListeningActivity?{if(!d.exists())return null;return ListeningActivity(d.getString("title") ?: "",d.getString("artist") ?: "",d.getString("artworkURL"),d.getBoolean("playing")==true,d.getTimestamp("expiresAt")?.toDate()?.time ?: 0)}}
}
private fun jsonMap(json:JSONObject):Map<String,Any> = json.keys().asSequence().mapNotNull{key -> val value=json.opt(key);if(value==null || value==JSONObject.NULL)null else key to jsonValue(value)}.toMap()
private fun jsonValue(value:Any):Any = when(value){is JSONObject->jsonMap(value);is org.json.JSONArray->(0 until value.length()).map{index -> val item=value.opt(index);if(item==null || item==JSONObject.NULL)null else jsonValue(item)};else->value}
