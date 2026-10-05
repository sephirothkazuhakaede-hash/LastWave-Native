package com.seph.capyflow
import org.junit.Assert.*
import org.junit.Test
class ChatReadPolicyTest {
    @Test fun newConversationIsNotObservedBeforeItsParentCommits(){
        assertFalse(ChatReadPolicy.canObserveThread(false,false))
        assertFalse(ChatReadPolicy.canObserveThread(true,true))
        assertTrue(ChatReadPolicy.canObserveThread(true,false))
    }
    @Test fun staleReadCallbackCannotOverwriteANewerMessage(){
        assertFalse(ChatReadPolicy.shouldMarkRead("first","second","peer","me",""))
        assertTrue(ChatReadPolicy.shouldMarkRead("second","second","peer","me","first"))
    }
    @Test fun outgoingAndAlreadyReadMessagesDoNotWriteReceipts(){
        assertFalse(ChatReadPolicy.shouldMarkRead("second","second","me","me","first"))
        assertFalse(ChatReadPolicy.shouldMarkRead("second","second","peer","me","second"))
        assertFalse(ChatReadPolicy.shouldMarkRead("second",null,null,"me",""))
    }
}
