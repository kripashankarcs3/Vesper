package com.example.wa_shield

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatSnapshotTrackerTest {
    private val pkg = "com.whatsapp"

    private fun notif(
        chatKey: String,
        vararg msgs: ParsedMessage,
        title: String = "Alice",
        isGroup: Boolean = false,
        summary: Boolean = false,
        category: String? = null,
    ) = ParsedNotification(pkg, chatKey, title, isGroup, msgs.toList(), summary, category)

    private val chat = "$pkg|t:alice"
    private val m1 = ParsedMessage("Alice", "hi", 1_000)
    private val m2 = ParsedMessage("Alice", "how are you", 2_000)
    private val m3 = ParsedMessage("Alice", "call me", 3_000)

    private fun List<CaptureEvent>.news() = filterIsInstance<CaptureEvent.NewMessage>()
    private fun List<CaptureEvent>.dels() = filterIsInstance<CaptureEvent.Deleted>()

    @Test
    fun newMessage_isEmittedWithStableUid() {
        val t = ChatSnapshotTracker()
        val ev = t.onPosted(notif(chat, m1))
        assertEquals(1, ev.news().size)
        val n = ev.news().single()
        assertEquals("hi", n.text)
        assertEquals("Alice", n.sender)
        assertEquals(1_000L, n.timestamp)
        assertEquals(CaptureRules.messageUid(pkg, chat, "Alice", 1_000, "hi"), n.uid)

        val ev2 = t.onPosted(notif(chat, m1, m2))
        assertEquals(listOf("how are you"), ev2.news().map { it.text })
        assertTrue(ev2.dels().isEmpty())
    }

    @Test
    fun repostWithSameMessages_producesNoDuplicates() {
        val t = ChatSnapshotTracker()
        t.onPosted(notif(chat, m1, m2))
        assertTrue(t.onPosted(notif(chat, m1, m2)).isEmpty())
        assertTrue(t.onPosted(notif(chat, m1, m2)).isEmpty())
    }

    @Test
    fun oneMessageVanished_isDeleted() {
        val t = ChatSnapshotTracker()
        t.onPosted(notif(chat, m1, m2, m3))
        val ev = t.onPosted(notif(chat, m1, m3))
        assertEquals(listOf(CaptureRules.messageUid(pkg, chat, "Alice", 2_000, "how are you")), ev.dels().map { it.uid })
        assertTrue(ev.news().isEmpty())
    }

    @Test
    fun newestMessageVanished_withoutNewOnes_isDeleted() {
        val t = ChatSnapshotTracker()
        t.onPosted(notif(chat, m1, m2))
        val ev = t.onPosted(notif(chat, m1))
        assertEquals(1, ev.dels().size)
    }

    @Test
    fun vanishedFromMiddle_whileNewMessageArrives_isDeleted() {
        val t = ChatSnapshotTracker()
        t.onPosted(notif(chat, m1, m2))
        val m4 = ParsedMessage("Alice", "new", 4_000)
        val ev = t.onPosted(notif(chat, m1, m4))
        assertEquals(1, ev.dels().size)
        assertEquals(listOf("new"), ev.news().map { it.text })
    }

    @Test
    fun oldestDroppedWhenNewArrives_isTruncationNotDeletion() {
        val t = ChatSnapshotTracker()
        t.onPosted(notif(chat, m1, m2, m3))
        val m4 = ParsedMessage("Alice", "four", 4_000)
        val ev = t.onPosted(notif(chat, m2, m3, m4))
        assertTrue(ev.dels().isEmpty())
        assertEquals(1, ev.news().size)
    }

    @Test
    fun allClearedOnRead_noDeletion() {
        val t = ChatSnapshotTracker()
        t.onPosted(notif(chat, m1, m2))
        // Notification removed because the user opened / read the chat.
        assertTrue(t.onRemoved(chat).isEmpty())
        // Next message arrives in a fresh notification: no deletions either.
        val m4 = ParsedMessage("Alice", "later", 5_000)
        val ev = t.onPosted(notif(chat, m4))
        assertTrue(ev.dels().isEmpty())
        assertEquals(1, ev.news().size)
    }

    @Test
    fun repostWithNoMessages_isClearNotDeletion() {
        val t = ChatSnapshotTracker()
        t.onPosted(notif(chat, m1, m2))
        assertTrue(t.onPosted(notif(chat)).isEmpty())
        assertTrue(t.onPosted(notif(chat, m1)).dels().isEmpty())
    }

    @Test
    fun staleSnapshot_completelyNewSet_isNotDeletion() {
        val t = ChatSnapshotTracker()
        t.onPosted(notif(chat, m1, m2))
        // Removal was missed (process dead); chat was read; a new message comes.
        val ev = t.onPosted(notif(chat, ParsedMessage("Alice", "x", 9_000)))
        assertTrue(ev.dels().isEmpty())
    }

    @Test
    fun groupTitleFormatChange_isSameChat() {
        val a = CaptureRules.chatKey(pkg, null, null, "Family", true, "Bob")
        val b = CaptureRules.chatKey(pkg, null, null, "Family: ~ Bob", true, "Bob")
        val c = CaptureRules.chatKey(pkg, null, null, "Family (3 messages): Bob", true, "Bob")
        val d = CaptureRules.chatKey(pkg, null, "Family", "Family: ~ Carol", true, "Carol")
        assertEquals(a, b)
        assertEquals(a, c)
        assertEquals(a, d)
        // shortcutId wins whenever present
        assertEquals(
            CaptureRules.chatKey(pkg, "123@g.us", null, "Family", true, null),
            CaptureRules.chatKey(pkg, "123@g.us", null, "Family: ~ Bob", true, null),
        )
        // packages never mix
        assertNotEquals(a, CaptureRules.chatKey("com.whatsapp.w4b", null, null, "Family", true, "Bob"))

        val t = ChatSnapshotTracker()
        val g1 = ParsedMessage("Bob", "hello all", 1_000)
        val g2 = ParsedMessage("Carol", "hey", 2_000)
        t.onPosted(ParsedNotification(pkg, a, "Family", true, listOf(g1)))
        val ev = t.onPosted(ParsedNotification(pkg, b, "Family", true, listOf(g1, g2)))
        assertEquals(listOf("hey"), ev.news().map { it.text })
        assertTrue(ev.dels().isEmpty())
    }

    @Test
    fun oneToOneCountSuffix_isSameChat() {
        assertEquals(
            CaptureRules.chatKey(pkg, null, null, "Alice", false, "Alice"),
            CaptureRules.chatKey(pkg, null, null, "Alice (2 messages)", false, "Alice"),
        )
    }

    @Test
    fun callTexts_areIgnored() {
        val t = ChatSnapshotTracker()
        for (txt in listOf(
            "Ringing…", "Calling…", "Incoming voice call", "Incoming video call",
            "Missed voice call", "Missed video call", "Ongoing voice call", "Ongoing video call 02:13",
            "WhatsApp Web is currently active", "Checking for new messages", "Backing up messages",
            "5 new messages", "12 messages from 3 chats", "",
        )) {
            assertTrue("should ignore '$txt'", CaptureRules.isIgnoredText(txt))
            assertTrue(t.onPosted(notif(chat, ParsedMessage("Alice", txt, 7_000))).isEmpty())
        }
        assertFalse(CaptureRules.isIgnoredText("I'll be calling you later"))
        assertFalse(CaptureRules.isIgnoredText("ringing the bell now?"))

        // CATEGORY_CALL notifications and group summaries are dropped entirely.
        assertTrue(t.onPosted(notif(chat, m1, category = CaptureRules.CATEGORY_CALL)).isEmpty())
        assertTrue(t.onPosted(notif(chat, m1, summary = true)).isEmpty())
    }

    @Test
    fun callTextPost_doesNotDisturbSnapshot() {
        val t = ChatSnapshotTracker()
        t.onPosted(notif(chat, m1, m2))
        assertTrue(t.onPosted(notif(chat, ParsedMessage("Alice", "Ringing…", 9_000))).isEmpty())
        assertTrue(t.onPosted(notif(chat, m1, m2)).isEmpty())
    }

    @Test
    fun deletedPlaceholder_marksOriginalAndIsNotStored() {
        val t = ChatSnapshotTracker()
        t.onPosted(notif(chat, m1, m2))
        val ev = t.onPosted(notif(chat, m1, ParsedMessage("Alice", "This message was deleted", 2_000)))
        assertTrue(ev.news().isEmpty())
        assertEquals(listOf(CaptureRules.messageUid(pkg, chat, "Alice", 2_000, "how are you")), ev.dels().map { it.uid })
        // Re-post of the same state must not fire again.
        assertTrue(t.onPosted(notif(chat, m1, ParsedMessage("Alice", "This message was deleted", 2_000))).isEmpty())
    }

    @Test
    fun deletedPlaceholder_unknownOriginal_resolvesInDb() {
        val t = ChatSnapshotTracker()
        val hindi = "यह संदेश हटा दिया गया"
        assertTrue(CaptureRules.isDeletionMarker(hindi))
        assertTrue(CaptureRules.isDeletionMarker("🚫 This message was deleted"))
        val ev = t.onPosted(notif(chat, ParsedMessage("Alice", "This message was deleted", 5_000)))
        val d = ev.filterIsInstance<CaptureEvent.DeleteLatestFromSender>().single()
        assertEquals("Alice", d.sender)
        assertEquals(5_000L, d.beforeTs)
        assertTrue(ev.news().isEmpty())
    }

    @Test
    fun mediaPolicy() {
        val cutoff = 10_000L
        assertTrue(MediaPolicy.shouldBackup("IMG-1.jpg", 900L * 1024 * 1024, 20_000, cutoff))
        assertTrue(MediaPolicy.shouldBackup("VID-1.mp4", 50L * 1024 * 1024, 20_000, cutoff))
        assertFalse(MediaPolicy.shouldBackup("VID-2.mp4", 50L * 1024 * 1024 + 1, 20_000, cutoff))
        assertFalse(MediaPolicy.shouldBackup("IMG-old.jpg", 100, 9_999, cutoff))
        assertFalse(MediaPolicy.shouldBackup(".nomedia", 0, 20_000, cutoff))
        assertFalse(MediaPolicy.shouldBackup("IMG-3.jpg.tmp", 100, 20_000, cutoff))
        assertFalse(MediaPolicy.shouldBackup("IMG-4.jpg", 0, 20_000, cutoff))
        assertFalse(MediaPolicy.shouldBackup("notes.opus", 100, 20_000, cutoff))
    }
}
