package io.github.evokelektrique.tunnelforge

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.annotation.Keep
import androidx.work.Worker
import androidx.work.WorkerParameters
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * WorkManager worker that updates one subscription on its periodic schedule.
 * Routes through the live Flutter UI engine when attached, or spawns a short-lived
 * headless [FlutterEngine] executing `subscriptionBackgroundMain` when the app is closed.
 */
@Keep
class SubscriptionAutoUpdateWorker(
    appContext: Context,
    params: WorkerParameters,
) : Worker(appContext, params) {

    private val mainHandler = Handler(Looper.getMainLooper())

    override fun doWork(): Result {
        val subscriptionId = inputData.getString(KEY_SUBSCRIPTION_ID)?.trim().orEmpty()
        if (subscriptionId.isEmpty()) {
            return Result.failure()
        }

        return syncLock.withLock {
            val outcome =
                try {
                    val liveChannel = SubscriptionLiveBridge.activeChannel()
                    if (liveChannel != null) {
                        runOnLiveEngine(liveChannel, subscriptionId)
                    } else {
                        runOnHeadlessEngine(subscriptionId)
                    }
                } catch (t: Throwable) {
                    AppLog.w(TAG, "Scheduled subscription update failed id=$subscriptionId: ${t.message}")
                    SubscriptionNotification.cancelProgress(applicationContext)
                    SubscriptionContract.OUTCOME_RETRY
                }

            when (outcome) {
                SubscriptionContract.OUTCOME_SUCCESS -> Result.success()
                SubscriptionContract.OUTCOME_FAILURE -> Result.failure()
                else ->
                    if (runAttemptCount < MAX_RETRY_ATTEMPTS) {
                        Result.retry()
                    } else {
                        Result.failure()
                    }
            }
        }
    }

    private fun runOnLiveEngine(
        channel: MethodChannel,
        subscriptionId: String,
    ): String {
        val latch = CountDownLatch(1)
        val outcomeRef = AtomicReference(SubscriptionContract.OUTCOME_RETRY)
        mainHandler.post {
            if (isStopped) {
                outcomeRef.set(SubscriptionContract.OUTCOME_RETRY)
                latch.countDown()
                return@post
            }
            try {
                channel.invokeMethod(
                    SubscriptionContract.METHOD_RUN_SCHEDULED_UPDATE,
                    mapOf(
                        SubscriptionContract.ARG_SUBSCRIPTION_ID to subscriptionId,
                        SubscriptionContract.ARG_IS_BACKGROUND to false,
                    ),
                    object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            outcomeRef.set(result?.toString() ?: SubscriptionContract.OUTCOME_SUCCESS)
                            latch.countDown()
                        }

                        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                            AppLog.w(TAG, "Live subscription update error id=$subscriptionId code=$errorCode")
                            outcomeRef.set(SubscriptionContract.OUTCOME_RETRY)
                            latch.countDown()
                        }

                        override fun notImplemented() {
                            // UI engine is still initializing (e.g. onboarding); retry later.
                            outcomeRef.set(SubscriptionContract.OUTCOME_RETRY)
                            latch.countDown()
                        }
                    },
                )
            } catch (t: Throwable) {
                AppLog.w(TAG, "Live subscription dispatch failed id=$subscriptionId: ${t.message}")
                outcomeRef.set(SubscriptionContract.OUTCOME_RETRY)
                latch.countDown()
            }
        }
        val completed = latch.await(WORKER_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        if (!completed) {
            SubscriptionNotification.cancelProgress(applicationContext)
            return SubscriptionContract.OUTCOME_RETRY
        }
        return outcomeRef.get()
    }

    private fun runOnHeadlessEngine(subscriptionId: String): String {
        val latch = CountDownLatch(1)
        val outcomeRef = AtomicReference(SubscriptionContract.OUTCOME_RETRY)
        val engineRef = AtomicReference<FlutterEngine?>(null)

        mainHandler.post {
            if (isStopped) {
                outcomeRef.set(SubscriptionContract.OUTCOME_RETRY)
                latch.countDown()
                return@post
            }
            try {
                val loader = FlutterInjector.instance().flutterLoader()
                if (!loader.initialized()) {
                    loader.startInitialization(applicationContext)
                }
                loader.ensureInitializationComplete(applicationContext, null)
                val engine = FlutterEngine(applicationContext)
                engineRef.set(engine)

                val messenger = engine.dartExecutor.binaryMessenger
                SubscriptionChannelHandler.attachDiagnosticsForHeadless(messenger)
                val channel = MethodChannel(messenger, SubscriptionContract.METHOD_CHANNEL)
                channel.setMethodCallHandler(
                    SubscriptionChannelHandler(
                        context = applicationContext,
                        onBackgroundRunnerReady = {
                            channel.invokeMethod(
                                SubscriptionContract.METHOD_RUN_SCHEDULED_UPDATE,
                                mapOf(
                                    SubscriptionContract.ARG_SUBSCRIPTION_ID to subscriptionId,
                                    SubscriptionContract.ARG_IS_BACKGROUND to true,
                                ),
                                object : MethodChannel.Result {
                                    override fun success(result: Any?) {
                                        outcomeRef.set(
                                            result?.toString() ?: SubscriptionContract.OUTCOME_SUCCESS,
                                        )
                                        latch.countDown()
                                    }

                                    override fun error(
                                        errorCode: String,
                                        errorMessage: String?,
                                        errorDetails: Any?,
                                    ) {
                                        AppLog.w(
                                            TAG,
                                            "Headless subscription update error id=$subscriptionId code=$errorCode",
                                        )
                                        outcomeRef.set(SubscriptionContract.OUTCOME_RETRY)
                                        latch.countDown()
                                    }

                                    override fun notImplemented() {
                                        outcomeRef.set(SubscriptionContract.OUTCOME_FAILURE)
                                        latch.countDown()
                                    }
                                },
                            )
                        },
                    ),
                )

                val entrypoint =
                    DartExecutor.DartEntrypoint(
                        loader.findAppBundlePath(),
                        BACKGROUND_ENTRYPOINT_NAME,
                    )
                engine.dartExecutor.executeDartEntrypoint(entrypoint)
            } catch (t: Throwable) {
                AppLog.e(TAG, "Headless subscription engine startup failed id=$subscriptionId", t)
                outcomeRef.set(SubscriptionContract.OUTCOME_RETRY)
                latch.countDown()
            }
        }

        val completed =
            try {
                latch.await(WORKER_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            } finally {
                val destroyLatch = CountDownLatch(1)
                mainHandler.post {
                    try {
                        engineRef.getAndSet(null)?.destroy()
                    } catch (t: Throwable) {
                        AppLog.w(TAG, "Headless subscription engine destroy error: ${t.message}")
                    } finally {
                        destroyLatch.countDown()
                    }
                }
                val savedInterrupt = Thread.interrupted()
                try {
                    destroyLatch.await(10L, TimeUnit.SECONDS)
                } finally {
                    if (savedInterrupt) Thread.currentThread().interrupt()
                }
            }

        if (!completed) {
            SubscriptionNotification.cancelProgress(applicationContext)
            return SubscriptionContract.OUTCOME_RETRY
        }
        return outcomeRef.get()
    }

    companion object {
        const val KEY_SUBSCRIPTION_ID = "subscriptionId"
        private const val TAG = "SubscriptionWorker"
        private const val BACKGROUND_ENTRYPOINT_NAME = "subscriptionBackgroundMain"
        private const val WORKER_TIMEOUT_SECONDS = 90L
        private const val MAX_RETRY_ATTEMPTS = 3
        private val syncLock = ReentrantLock()
    }
}
