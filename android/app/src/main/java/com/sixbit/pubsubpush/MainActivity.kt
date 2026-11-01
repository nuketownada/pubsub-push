package com.sixbit.pubsubpush

import android.Manifest
import android.app.Activity
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import org.unifiedpush.android.connector.UnifiedPush

/** Settings: bridge URL and topics, plus registration status. */
class MainActivity : Activity() {
    private lateinit var prefs: Prefs
    private lateinit var status: TextView
    private val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, _ ->
        runOnUiThread { showStatus() }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        prefs = Prefs(this)
        status = findViewById(R.id.status)
        val bridge = findViewById<EditText>(R.id.bridge_url)
        val topics = findViewById<EditText>(R.id.topics)
        bridge.setText(prefs.bridgeUrl)
        topics.setText(prefs.topics.joinToString("\n"))

        findViewById<Button>(R.id.save).setOnClickListener {
            prefs.bridgeUrl = bridge.text.toString()
            prefs.topics = topics.text.split('\n', ',', ' ')
            register()
        }

        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
        if (prefs.topics.isNotEmpty()) register()
    }

    override fun onResume() {
        super.onResume()
        prefs.sp.registerOnSharedPreferenceChangeListener(listener)
        showStatus()
    }

    override fun onPause() {
        prefs.sp.unregisterOnSharedPreferenceChangeListener(listener)
        super.onPause()
    }

    /** Make sure we're registered with the distributor, then with the bridge. */
    private fun register() {
        UnifiedPush.tryUseCurrentOrDefaultDistributor(this) { ok ->
            if (ok) {
                // Re-registering returns the current endpoint (onNewEndpoint),
                // which schedules the bridge registration.
                UnifiedPush.register(this, messageForDistributor = getString(R.string.app_name))
                if (prefs.endpoint != null) RegisterJob.schedule(this)
            } else {
                prefs.status = getString(R.string.no_distributor)
            }
        }
    }

    private fun showStatus() {
        val distributor = UnifiedPush.getAckDistributor(this) ?: "none"
        val results = prefs.topicResults.entries.joinToString("\n") { "  ${it.key}: ${it.value}" }
        status.text = buildString {
            appendLine(prefs.status)
            appendLine()
            appendLine("Distributor: $distributor")
            appendLine("Endpoint: ${if (prefs.endpoint != null) "yes" else "no"}")
            if (results.isNotEmpty()) {
                appendLine("Topics:")
                append(results)
            }
        }
    }
}
