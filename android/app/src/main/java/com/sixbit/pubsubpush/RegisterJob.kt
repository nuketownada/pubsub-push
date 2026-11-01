package com.sixbit.pubsubpush

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context

/**
 * Registers the current endpoint and topics with the bridge once the network
 * is up, retrying with backoff. Scheduled on every new endpoint (the
 * distributor renews daily) and on settings changes.
 */
class RegisterJob : JobService() {
    override fun onStartJob(params: JobParameters): Boolean {
        Thread {
            val outcome = Bridge.register(applicationContext)
            jobFinished(params, outcome == Bridge.Outcome.RETRY)
        }.start()
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean = true

    companion object {
        private const val JOB_ID = 1

        fun schedule(context: Context) {
            val job = JobInfo.Builder(JOB_ID, ComponentName(context, RegisterJob::class.java))
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                .setBackoffCriteria(30_000, JobInfo.BACKOFF_POLICY_EXPONENTIAL)
                .build()
            context.getSystemService(JobScheduler::class.java).schedule(job)
        }
    }
}
