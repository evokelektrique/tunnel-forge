package io.github.evokelektrique.tunnelforge

import android.content.Context
import androidx.core.content.edit
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.Data
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import java.util.concurrent.TimeUnit

internal data class SubscriptionScheduleSpec(
    val id: String,
    val autoUpdate: Boolean,
    val intervalMinutes: Long,
)

internal data class SubscriptionSchedulePlan(
    val enqueue: List<SubscriptionScheduleSpec>,
    val cancelIds: Set<String>,
    val nextTrackedIds: Set<String>,
)

/** Pure-JVM scheduling diff policy for WorkManager periodic subscription updates. */
internal object SubscriptionSchedulePolicy {
    const val MIN_INTERVAL_MINUTES = 15L
    const val MAX_INTERVAL_MINUTES = 30L * 24L * 60L
    const val WORK_NAME_PREFIX = "subscription_auto_update_"

    fun uniqueWorkName(subscriptionId: String): String = "$WORK_NAME_PREFIX$subscriptionId"

    fun clampIntervalMinutes(value: Long): Long =
        value.coerceIn(MIN_INTERVAL_MINUTES, MAX_INTERVAL_MINUTES)

    fun plan(
        previouslyScheduledIds: Set<String>,
        requested: List<SubscriptionScheduleSpec>,
    ): SubscriptionSchedulePlan {
        val enqueue = mutableListOf<SubscriptionScheduleSpec>()
        val activeIds = LinkedHashSet<String>()
        val cancelIds = LinkedHashSet<String>()

        for (spec in requested) {
            val cleanId = spec.id.trim()
            if (cleanId.isEmpty()) continue
            if (spec.autoUpdate) {
                activeIds.add(cleanId)
                enqueue.add(
                    SubscriptionScheduleSpec(
                        id = cleanId,
                        autoUpdate = true,
                        intervalMinutes = clampIntervalMinutes(spec.intervalMinutes),
                    ),
                )
            } else {
                cancelIds.add(cleanId)
            }
        }
        for (oldId in previouslyScheduledIds) {
            if (oldId !in activeIds) {
                cancelIds.add(oldId)
            }
        }
        return SubscriptionSchedulePlan(
            enqueue = enqueue,
            cancelIds = cancelIds,
            nextTrackedIds = activeIds,
        )
    }
}

internal object SubscriptionWorkScheduler {
    private const val PREFS_NAME = "tunnel_forge_subscription_schedules"
    private const val KEY_SCHEDULED_IDS = "scheduled_subscription_ids"
    private const val TAG = "SubscriptionScheduler"

    fun syncSchedules(context: Context, rawSpecs: List<*>) {
        val appContext = context.applicationContext
        val specs =
            rawSpecs.mapNotNull { entry ->
                val map = entry as? Map<*, *> ?: return@mapNotNull null
                val id = map[SubscriptionContract.ARG_ID]?.toString()?.trim().orEmpty()
                if (id.isEmpty()) return@mapNotNull null
                val autoUpdate = map[SubscriptionContract.ARG_AUTO_UPDATE] == true
                val interval =
                    (map[SubscriptionContract.ARG_INTERVAL_MINUTES] as? Number)?.toLong()
                        ?: (24L * 60L)
                SubscriptionScheduleSpec(
                    id = id,
                    autoUpdate = autoUpdate,
                    intervalMinutes = interval,
                )
            }

        val prefs = appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val previous = prefs.getStringSet(KEY_SCHEDULED_IDS, emptySet())?.toSet().orEmpty()
        val plan = SubscriptionSchedulePolicy.plan(previous, specs)
        val workManager = WorkManager.getInstance(appContext)

        for (cancelId in plan.cancelIds) {
            workManager.cancelUniqueWork(SubscriptionSchedulePolicy.uniqueWorkName(cancelId))
        }

        val constraints =
            Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
                .build()

        for (spec in plan.enqueue) {
            val inputData =
                Data.Builder()
                    .putString(SubscriptionAutoUpdateWorker.KEY_SUBSCRIPTION_ID, spec.id)
                    .build()
            val request =
                PeriodicWorkRequestBuilder<SubscriptionAutoUpdateWorker>(
                    spec.intervalMinutes,
                    TimeUnit.MINUTES,
                )
                    .setConstraints(constraints)
                    .setInputData(inputData)
                    .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 5L, TimeUnit.MINUTES)
                    .build()
            workManager.enqueueUniquePeriodicWork(
                SubscriptionSchedulePolicy.uniqueWorkName(spec.id),
                ExistingPeriodicWorkPolicy.UPDATE,
                request,
            )
        }

        prefs.edit { putStringSet(KEY_SCHEDULED_IDS, plan.nextTrackedIds) }
        AppLog.d(
            TAG,
            "Synced WorkManager schedules active=${plan.enqueue.size} canceled=${plan.cancelIds.size}",
        )
    }
}
