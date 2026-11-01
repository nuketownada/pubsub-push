package com.sixbit.pubsubpush

import org.unifiedpush.android.connector.FailedReason
import org.unifiedpush.android.connector.PushService
import org.unifiedpush.android.connector.data.PushEndpoint
import org.unifiedpush.android.connector.data.PushMessage

/** UnifiedPush events from the distributor (Conversations). */
class PushServiceImpl : PushService() {
    override fun onNewEndpoint(endpoint: PushEndpoint, instance: String) {
        val prefs = Prefs(this)
        prefs.endpoint = endpoint.url
        prefs.status = "Got an endpoint, registering with the bridge…"
        RegisterJob.schedule(this)
    }

    override fun onMessage(message: PushMessage, instance: String) {
        // The bridge sends plain JSON; the connector hands it over undecrypted.
        Notifier.show(this, message.content)
    }

    override fun onRegistrationFailed(reason: FailedReason, instance: String) {
        Prefs(this).status = "Distributor registration failed: $reason."
    }

    override fun onUnregistered(instance: String) {
        val prefs = Prefs(this)
        val endpoint = prefs.endpoint
        prefs.endpoint = null
        prefs.status = "Unregistered by the distributor."
        if (endpoint != null) {
            val url = prefs.bridgeUrl
            Thread { Bridge.unregister(url, endpoint) }.start()
        }
    }
}
