package com.example.wa_shield

import java.security.MessageDigest

// =============================================================================
// PURE capture logic (no android.* imports) so it can be unit tested on the JVM.
//
// The Android layer (NotificationParser / CaptureListenerService) turns a
// StatusBarNotification into a [ParsedNotification]; [ChatSnapshotTracker]
// turns the sequence of parsed notifications into [CaptureEvent]s.
// =============================================================================

/** One incoming message as shown in a WhatsApp MessagingStyle notification. */
data class ParsedMessage(
    val sender: String,
    val text: String,
    /** The message's own timestamp (MessagingStyle.Message.timestamp), not the post time. */
    val timestamp: Long,
)

data class ParsedNotification(
    val packageName: String,
    /** Stable per-chat key, see [CaptureRules.chatKey]. */
    val chatKey: String,
    /** Human readable chat name (group name, or contact name for 1:1). */
    val chatTitle: String,
    val isGroup: Boolean,
    /** Incoming messages only (the device user's own messages are dropped by the parser). */
    val messages: List<ParsedMessage>,
    val isGroupSummary: Boolean = false,
    val category: String? = null,
)

sealed class CaptureEvent {
    data class NewMessage(
        val uid: String,
        val packageName: String,
        val chatKey: String,
        val chatTitle: String,
        val isGroup: Boolean,
        val sender: String,
        val text: String,
        val timestamp: Long,
    ) : CaptureEvent()

    /** A previously captured message (by uid) was deleted for everyone. */
    data class Deleted(val uid: String, val packageName: String, val chatKey: String) : CaptureEvent()

    /**
     * A "This message was deleted" placeholder arrived but the original message is
     * not in our snapshot: the Dart side marks the newest not-yet-deleted message
     * from [sender] in [chatKey] with timestamp <= [beforeTs].
     */
    data class DeleteLatestFromSender(
        val packageName: String,
        val chatKey: String,
        val sender: String,
        val beforeTs: Long,
    ) : CaptureEvent()
}

/** One remembered message of a chat snapshot (no message text is kept). */
data class SnapshotEntry(
    val uid: String,
    val timestamp: Long,
    val sender: String,
    /** True for an already-processed "This message was deleted" placeholder. */
    val marker: Boolean = false,
)

object CaptureRules {
    const val CATEGORY_CALL = "call" // == Notification.CATEGORY_CALL

    // Hindi placeholder that WhatsApp shows for a revoked message (kept as
    // unicode escapes on purpose).
    private const val HINDI_DELETED =
        "यह संदेश हटा दिया गया"

    private val DELETION_MARKERS = setOf(
        "this message was deleted",
        "you deleted this message",
        HINDI_DELETED,
    )

    /** Call / status / system texts that are never real chat messages (normalised, exact). */
    private val IGNORED_EXACT = setOf(
        "ringing",
        "calling",
        "incoming voice call",
        "incoming video call",
        "missed voice call",
        "missed video call",
        "ongoing voice call",
        "ongoing video call",
        "whatsapp web is currently active",
        "checking for new messages",
        "backing up messages",
        "connecting",
        "reconnecting",
    )
    private val IGNORED_PREFIXES = listOf(
        "ongoing voice call",
        "ongoing video call",
        "missed voice call",
        "missed video call",
        "incoming voice call",
        "incoming video call",
        "backing up messages",
        "whatsapp web is currently active",
    )
    private val NEW_MESSAGES_RE = Regex("""^\d+\s+(new\s+)?messages?(\s+from\s+\d+\s+chats?)?$""")
    private val MISSED_CALLS_RE = Regex("""^\d+\s+missed\s+(voice\s+|video\s+)?calls?$""")

    /** Lowercase, trim, strip leading emoji/symbols and trailing dots / ellipsis. */
    fun normalizeText(text: String): String {
        var s = text.trim().lowercase()
        s = s.trimStart { !it.isLetterOrDigit() }
        s = s.trimEnd { it == '.' || it == '…' || it.isWhitespace() || it == '!' }
        return s.replace(Regex("\\s+"), " ")
    }

    fun isDeletionMarker(text: String): Boolean = normalizeText(text) in DELETION_MARKERS

    fun isIgnoredText(text: String): Boolean {
        if (text.isBlank()) return true
        val n = normalizeText(text)
        if (n.isEmpty()) return true
        if (n in IGNORED_EXACT) return true
        if (IGNORED_PREFIXES.any { n.startsWith(it) } && n.length <= 60) return true
        if (NEW_MESSAGES_RE.matches(n)) return true
        if (MISSED_CALLS_RE.matches(n)) return true
        return false
    }

    private val COUNT_SUFFIX_RE = Regex("""\s*\(\d+\s+(new\s+)?messages?\)\s*$""", RegexOption.IGNORE_CASE)
    private val INVISIBLE_RE = Regex("[​-‏‪-‮⁦-⁩﻿]")

    /**
     * Removes WhatsApp's decorations from a chat title: invisible bidi marks, a
     * trailing "(3 messages)", and — for groups — the ": ~ Sender" / ": Sender"
     * suffix that WhatsApp appends to the title of the newest message.
     */
    fun normalizeTitle(title: String, isGroup: Boolean): String {
        var s = INVISIBLE_RE.replace(title, "").trim()
        if (isGroup) {
            val idx = s.indexOf(": ")
            if (idx > 0) s = s.substring(0, idx).trim()
        }
        s = COUNT_SUFFIX_RE.replace(s, "").trim()
        return s
    }

    /**
     * Stable chat key, independent of title decorations:
     *   1. the notification's shortcutId (WhatsApp uses the chat JID) if present,
     *   2. else the MessagingStyle conversation title (normalised),
     *   3. else the notification title (normalised),
     *   4. else the first sender.
     * Always prefixed with the package so WhatsApp and WhatsApp Business never mix.
     */
    fun chatKey(
        packageName: String,
        shortcutId: String?,
        conversationTitle: String?,
        title: String?,
        isGroup: Boolean,
        firstSender: String?,
    ): String {
        val id = when {
            !shortcutId.isNullOrBlank() -> "s:" + shortcutId.trim()
            !conversationTitle.isNullOrBlank() -> "t:" + normalizeTitle(conversationTitle, isGroup).lowercase()
            !title.isNullOrBlank() -> "t:" + normalizeTitle(title, isGroup).lowercase()
            else -> "u:" + (firstSender ?: "").trim().lowercase()
        }
        return "$packageName|$id"
    }

    /** Stable message UID = SHA-256(package, chat key, sender, timestamp, text), 128-bit hex. */
    fun messageUid(packageName: String, chatKey: String, sender: String, timestamp: Long, text: String): String {
        val md = MessageDigest.getInstance("SHA-256")
        val raw = listOf(packageName, chatKey, sender, timestamp.toString(), text).joinToString("\u0000")
        val digest = md.digest(raw.toByteArray(Charsets.UTF_8))
        return digest.take(16).joinToString("") { "%02x".format(it) }
    }
}

/**
 * Per-chat snapshot / diff engine.
 *
 * DELETION RULES (WhatsApp usually just drops a revoked message from its
 * MessagingStyle notification instead of posting "This message was deleted"):
 *
 *  R1  For every chat we remember the UIDs of the last posted snapshot.
 *  R2  On a new post for the same chat, a remembered UID that is MISSING is a
 *      deletion, provided the notification still shows at least one real
 *      message (it still exists and was not cleared).
 *  R3  Exception — history truncation: when the post also ADDS new messages,
 *      WhatsApp may drop the oldest ones to stay within its limit. A missing UID
 *      that is not newer than every retained message (i.e. part of the dropped
 *      oldest prefix), or any missing UID when nothing was retained, is treated
 *      as truncation, NOT deletion. A message that vanished from the middle /
 *      end while older ones are still present is a deletion.
 *  R4  A post whose messages are all gone (only ignored texts or nothing) is a
 *      "cleared" state (chat read) — never a deletion; the snapshot is reset.
 *  R5  A message whose text is "This message was deleted" (or the Hindi
 *      variant) is not stored; it marks the newest earlier message from the same
 *      sender in that chat as deleted (from the snapshot if known, otherwise via
 *      [CaptureEvent.DeleteLatestFromSender] resolved against the DB).
 *  R6  [onRemoved] NEVER produces deletions: a removal is how WhatsApp reacts to
 *      the user opening/reading the chat (REASON_CLICK, REASON_APP_CANCEL, ...),
 *      and that cannot be told apart from a revoke. It only forgets the snapshot.
 *  R7  Group summaries and CATEGORY_CALL notifications are ignored entirely, as
 *      are call/status/system texts ([CaptureRules.isIgnoredText]) and empty
 *      texts. Posts consisting only of ignored texts leave the snapshot untouched.
 *
 * Dedupe: identical re-posts produce no NewMessage events (UID already in the
 * snapshot); the DB additionally enforces UNIQUE(msg_uid), so a lost snapshot
 * (process restart) can at worst re-emit an event that is then ignored.
 */
class ChatSnapshotTracker(
    initial: Map<String, List<SnapshotEntry>> = emptyMap(),
    private val maxEntriesPerChat: Int = 60,
    private val maxChats: Int = 300,
) {
    // Access-ordered so the least recently updated chat is evicted first.
    private val snapshots = LinkedHashMap<String, List<SnapshotEntry>>(16, 0.75f, true)

    init {
        initial.forEach { (k, v) -> snapshots[k] = v }
    }

    @Synchronized
    fun export(): Map<String, List<SnapshotEntry>> = LinkedHashMap(snapshots)

    @Synchronized
    fun clear() = snapshots.clear()

    @Synchronized
    fun snapshotOf(chatKey: String): List<SnapshotEntry>? = snapshots[chatKey]?.toList()

    @Synchronized
    fun onPosted(n: ParsedNotification): List<CaptureEvent> {
        if (n.isGroupSummary) return emptyList()
        if (n.category == CaptureRules.CATEGORY_CALL) return emptyList()

        val markers = mutableListOf<ParsedMessage>()
        val real = mutableListOf<ParsedMessage>()
        for (m in n.messages) {
            if (m.text.isBlank()) continue
            when {
                CaptureRules.isDeletionMarker(m.text) -> markers.add(m)
                CaptureRules.isIgnoredText(m.text) -> {}
                else -> real.add(m)
            }
        }

        val prev = snapshots[n.chatKey]

        // Only ignored/system texts: not a chat update at all (R7).
        if (real.isEmpty() && markers.isEmpty()) {
            if (n.messages.isEmpty() && prev != null) {
                // Cleared notification (R4).
                snapshots.remove(n.chatKey)
            }
            return emptyList()
        }

        val entries = LinkedHashMap<String, Pair<SnapshotEntry, ParsedMessage>>()
        for (m in real) {
            val uid = CaptureRules.messageUid(n.packageName, n.chatKey, m.sender, m.timestamp, m.text)
            entries[uid] = SnapshotEntry(uid, m.timestamp, m.sender) to m
        }

        val events = mutableListOf<CaptureEvent>()
        val prevAll = prev ?: emptyList()
        val prevUids = prevAll.map { it.uid }.toSet()
        val prevReal = prevAll.filter { !it.marker }

        for ((uid, pair) in entries) {
            if (uid in prevUids) continue
            val m = pair.second
            events.add(
                CaptureEvent.NewMessage(
                    uid = uid,
                    packageName = n.packageName,
                    chatKey = n.chatKey,
                    chatTitle = n.chatTitle,
                    isGroup = n.isGroup,
                    sender = m.sender,
                    text = m.text,
                    timestamp = m.timestamp,
                )
            )
        }

        val deleted = LinkedHashSet<String>()
        if (prev != null && entries.isNotEmpty()) {
            val added = entries.keys.filter { it !in prevUids }
            val retained = prevReal.filter { it.uid in entries.keys }
            val missing = prevReal.filter { it.uid !in entries.keys }
            val oldestRetained = retained.minOfOrNull { it.timestamp }
            for (m in missing) {
                val truncated = added.isNotEmpty() &&
                    (oldestRetained == null || m.timestamp <= oldestRetained)
                if (!truncated) deleted.add(m.uid) // R2
            }
        }
        // When only placeholders are left (entries empty), R5 below decides.

        // R5: placeholder texts. A placeholder already seen in the previous
        // snapshot was handled then and is skipped (re-posts must not re-fire).
        val markerEntries = mutableListOf<SnapshotEntry>()
        for (mk in markers) {
            val markerUid = CaptureRules.messageUid(n.packageName, n.chatKey, mk.sender, mk.timestamp, "#deleted-placeholder")
            markerEntries.add(SnapshotEntry(markerUid, mk.timestamp, mk.sender, marker = true))
            if (markerUid in prevUids) continue
            val candidate = prevReal
                .filter { it.sender == mk.sender && it.timestamp <= mk.timestamp && it.uid !in entries.keys }
                .maxByOrNull { it.timestamp }
            if (candidate != null) {
                deleted.add(candidate.uid)
            } else {
                events.add(CaptureEvent.DeleteLatestFromSender(n.packageName, n.chatKey, mk.sender, mk.timestamp))
            }
        }

        deleted.forEach { events.add(CaptureEvent.Deleted(it, n.packageName, n.chatKey)) }

        snapshots[n.chatKey] = (entries.values.map { it.first } + markerEntries)
            .sortedBy { it.timestamp }
            .takeLast(maxEntriesPerChat)
        while (snapshots.size > maxChats) {
            val eldest = snapshots.keys.first()
            snapshots.remove(eldest)
        }
        return events
    }

    /** R6: removal (read / opened / dismissed) never yields deletions. */
    @Synchronized
    fun onRemoved(chatKey: String): List<CaptureEvent> {
        snapshots.remove(chatKey)
        return emptyList()
    }
}

/** Pure media backup policy (see MediaBackup). */
object MediaPolicy {
    const val MAX_VIDEO_BYTES = 50L * 1024 * 1024
    const val FIRST_SCAN_WINDOW_MS = 7L * 24 * 60 * 60 * 1000

    private val IMAGE_EXT = setOf("jpg", "jpeg", "png", "webp", "gif", "heic", "heif")
    private val VIDEO_EXT = setOf("mp4", "3gp", "mkv", "webm", "mov", "m4v")

    /** "image", "video" or null when the file must not be backed up by name alone. */
    fun mediaType(fileName: String): String? {
        if (fileName.isEmpty() || fileName.startsWith(".") || fileName.startsWith("~")) return null
        val lower = fileName.lowercase()
        if (lower.endsWith(".tmp") || lower.endsWith(".part") || lower.endsWith(".crdownload") ||
            lower.endsWith(".pending") || lower.endsWith(".temp")
        ) return null
        val ext = lower.substringAfterLast('.', "")
        return when (ext) {
            in IMAGE_EXT -> "image"
            in VIDEO_EXT -> "video"
            else -> null
        }
    }

    /**
     * Whether a file qualifies for backup. [cutoffMs] is fixed at the first scan
     * (first scan time - 7 days) and moved to "now" after a wipe, so older
     * history is never bulk-copied.
     */
    fun shouldBackup(fileName: String, sizeBytes: Long, lastModifiedMs: Long, cutoffMs: Long): Boolean {
        val type = mediaType(fileName) ?: return false
        if (sizeBytes <= 0) return false
        if (lastModifiedMs < cutoffMs) return false
        if (type == "video" && sizeBytes > MAX_VIDEO_BYTES) return false
        return true
    }
}
