package com.sixbit.pubsubpush

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/** Client for mod_pubsub_unified_push's registration API (docs/design.md). */
object Bridge {
    enum class Outcome { OK, RETRY, GIVE_UP }

    /** Sends {endpoint, topics}. Blocking: call off the main thread. */
    fun register(context: Context): Outcome {
        val prefs = Prefs(context)
        val endpoint = prefs.endpoint ?: return Outcome.OK // nothing to register yet
        val body = JSONObject()
            .put("endpoint", endpoint)
            .put("topics", JSONArray(prefs.topics))
        return try {
            val (code, response) = request("POST", prefs.bridgeUrl, body)
            when {
                code == 200 -> {
                    val results = response?.optJSONObject("topics")
                    prefs.topicResults = prefs.topics.associateWith { results?.optString(it, "?") ?: "?" }
                    prefs.status = "Registered with the bridge."
                    Outcome.OK
                }
                // 403: the bridge doesn't accept this endpoint (expired, or not
                // from this server); a new one comes with the next renewal.
                code in 400..499 -> {
                    prefs.status = "Bridge refused registration (HTTP $code)."
                    Outcome.GIVE_UP
                }
                else -> {
                    prefs.status = "Bridge unavailable (HTTP $code), retrying."
                    Outcome.RETRY
                }
            }
        } catch (e: IOException) {
            prefs.status = "Can't reach the bridge (${e.message}), retrying."
            Outcome.RETRY
        }
    }

    /** Best effort: the bridge also drops registrations that stop renewing. */
    fun unregister(bridgeUrl: String, endpoint: String) {
        try {
            request("DELETE", bridgeUrl, JSONObject().put("endpoint", endpoint))
        } catch (_: IOException) {
        }
    }

    private fun request(method: String, url: String, body: JSONObject): Pair<Int, JSONObject?> {
        val conn = URL(url).openConnection() as HttpURLConnection
        try {
            conn.requestMethod = method
            conn.connectTimeout = 15_000
            conn.readTimeout = 15_000
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/json")
            conn.outputStream.use { it.write(body.toString().toByteArray()) }
            val code = conn.responseCode
            val text = (if (code < 400) conn.inputStream else conn.errorStream)
                ?.bufferedReader()?.use { it.readText() }
            val json = text?.takeIf { it.startsWith("{") }?.let { JSONObject(it) }
            return code to json
        } finally {
            conn.disconnect()
        }
    }
}
