package com.sixbit.pubsubpush

import android.content.Context
import android.content.SharedPreferences

/** App state: settings, the current endpoint, and the last registration outcome. */
class Prefs(context: Context) {
    val sp: SharedPreferences = context.getSharedPreferences("pubsubpush", Context.MODE_PRIVATE)

    var bridgeUrl: String
        get() = sp.getString("bridge_url", null) ?: DEFAULT_BRIDGE
        set(v) = sp.edit().putString("bridge_url", v.trim()).apply()

    var topics: List<String>
        get() = (sp.getString("topics", null) ?: "").split(",").filter { it.isNotBlank() }
        set(v) = sp.edit().putString("topics", v.map { it.trim() }.filter { it.isNotEmpty() }.distinct().joinToString(",")).apply()

    /** UnifiedPush endpoint from the distributor; null until registered. */
    var endpoint: String?
        get() = sp.getString("endpoint", null)
        set(v) = sp.edit().putString("endpoint", v).apply()

    /** Human-readable status of the last thing that happened. */
    var status: String
        get() = sp.getString("status", null) ?: "Not registered yet."
        set(v) = sp.edit().putString("status", v).apply()

    /** Per-topic result of the last successful bridge registration, "topic=result,…". */
    var topicResults: Map<String, String>
        get() = (sp.getString("topic_results", null) ?: "").split(",").filter { "=" in it }
            .associate { it.substringBefore("=") to it.substringAfter("=") }
        set(v) = sp.edit().putString("topic_results", v.entries.joinToString(",") { "${it.key}=${it.value}" }).apply()

    /**
     * Records (topic, id) as shown; false if it already was. The bridge delivers
     * at least once, so a push that timed out may arrive again.
     */
    fun markSeen(topic: String, id: String): Boolean {
        val key = "$topic/$id"
        val seen = (sp.getString("seen", null) ?: "").split("\n").filter { it.isNotEmpty() }
        if (key in seen) return false
        sp.edit().putString("seen", (seen + key).takeLast(SEEN_MAX).joinToString("\n")).apply()
        return true
    }

    companion object {
        const val DEFAULT_BRIDGE = "https://xmpp.6bit.com/pubsub_push/register"
        private const val SEEN_MAX = 500
    }
}
