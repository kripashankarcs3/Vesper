package com.example.wa_shield

import android.app.Notification
import android.os.Build
import android.os.Bundle
import android.os.Parcelable
import android.service.notification.StatusBarNotification
import androidx.core.app.NotificationCompat
import androidx.core.app.Person

/** Turns a WhatsApp StatusBarNotification into a [ParsedNotification]. Never logs content. */
object NotificationParser {
    const val WHATSAPP = "com.whatsapp"
    const val WHATSAPP_BUSINESS = "com.whatsapp.w4b"
    private const val SHELL = "com.android.shell"
    private val DEBUG_TS_RE = Regex("""^@(\d{10,15}) (.*)$""", RegexOption.DOT_MATCHES_ALL)

    /** WhatsApp + WhatsApp Business; in DEBUG builds also adb-posted shell notifications for testing. */
    fun isSupportedPackage(pkg: String): Boolean =
        pkg == WHATSAPP || pkg == WHATSAPP_BUSINESS || (BuildConfig.DEBUG && pkg == SHELL)

    fun parse(sbn: StatusBarNotification): ParsedNotification? {
        val n = sbn.notification ?: return null
        val pkg = sbn.packageName
        val extras = n.extras ?: Bundle()
        val isSummary = (n.flags and Notification.FLAG_GROUP_SUMMARY) != 0
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()

        val style = try {
            NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(n)
        } catch (_: Exception) {
            null
        }

        val userKey = style?.user?.key

        val isGroup = style?.isGroupConversation
            ?: extras.getBoolean("android.isGroupConversation", false)
        val conversationTitle = (style?.conversationTitle
            ?: extras.getCharSequence("android.conversationTitle"))?.toString()

        val raw = mutableListOf<ParsedMessage>()
        if (style != null) {
            for (m in style.messages) {
                val person = m.person
                if (person == null || isSelf(person, userKey)) continue // device user's own message
                val sender = person.name?.toString()?.trim().orEmpty()
                raw.add(ParsedMessage(sender, m.text?.toString()?.trim().orEmpty(), m.timestamp))
            }
        } else {
            // Fallback: raw android.messages bundles.
            @Suppress("DEPRECATION")
            val arr: Array<Parcelable>? = extras.getParcelableArray(Notification.EXTRA_MESSAGES)
            if (arr != null) {
                for (p in arr) {
                    val b = p as? Bundle ?: continue
                    val text = b.getCharSequence("text")?.toString()?.trim().orEmpty()
                    val time = b.getLong("time", n.`when`)
                    var sender = b.getCharSequence("sender")?.toString()
                    if (sender == null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        @Suppress("DEPRECATION")
                        val ap = b.getParcelable<android.app.Person>("sender_person")
                        sender = ap?.name?.toString()
                    }
                    if (sender == null) continue // own message
                    raw.add(ParsedMessage(sender.trim(), text, time))
                }
            } else if (!isSummary) {
                // Plain notification: one message, sender = title.
                val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()?.trim().orEmpty()
                if (!title.isNullOrBlank() && text.isNotEmpty()) {
                    raw.add(ParsedMessage(CaptureRules.normalizeTitle(title, isGroup), text, n.`when`))
                }
            }
        }

        // For 1:1 chats MessagingStyle has no conversation title; the sender (or
        // the notification title) names the chat.
        var messages = raw.map { m ->
            if (m.sender.isEmpty()) m.copy(sender = CaptureRules.normalizeTitle(conversationTitle ?: title ?: "", isGroup)) else m
        }

        // DEBUG-ONLY test hook: `cmd notification post -S messaging` stamps every
        // message with the post time, so a re-post never looks identical. For
        // shell-posted notifications in debug builds a text of the form
        // "@<epochMillis> <text>" carries an explicit, stable message timestamp
        // (mimicking WhatsApp, whose timestamps are the real message times).
        if (BuildConfig.DEBUG && pkg == SHELL) {
            messages = messages.map { m ->
                val match = DEBUG_TS_RE.find(m.text)
                if (match != null) m.copy(timestamp = match.groupValues[1].toLong(), text = match.groupValues[2]) else m
            }
        }

        val shortcutId = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) n.shortcutId else null
        val chatKey = CaptureRules.chatKey(
            packageName = pkg,
            shortcutId = shortcutId,
            conversationTitle = conversationTitle,
            title = if (isGroup) title else (title ?: messages.firstOrNull()?.sender),
            isGroup = isGroup,
            firstSender = messages.firstOrNull()?.sender,
        )
        val chatTitle = when {
            !conversationTitle.isNullOrBlank() -> CaptureRules.normalizeTitle(conversationTitle, isGroup)
            !title.isNullOrBlank() -> CaptureRules.normalizeTitle(title, isGroup)
            else -> messages.firstOrNull()?.sender ?: ""
        }

        return ParsedNotification(
            packageName = pkg,
            chatKey = chatKey,
            chatTitle = chatTitle,
            isGroup = isGroup,
            messages = messages,
            isGroupSummary = isSummary,
            category = n.category,
        )
    }

    private fun isSelf(p: Person, userKey: String?): Boolean = userKey != null && p.key == userKey

    /** The reply action carrying a RemoteInput, if any (Ghost Reply). */
    fun replyAction(n: Notification): Notification.Action? {
        val actions = n.actions ?: return null
        return actions.firstOrNull { a -> a.remoteInputs?.any { it.allowFreeFormInput } == true }
    }
}
