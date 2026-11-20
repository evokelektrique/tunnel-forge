package io.github.evokelektrique.tunnelforge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SubscriptionSchedulePolicyTest {

    @Test
    fun clampsIntervalToWorkManagerBounds() {
        assertEquals(
            SubscriptionSchedulePolicy.MIN_INTERVAL_MINUTES,
            SubscriptionSchedulePolicy.clampIntervalMinutes(1L),
        )
        assertEquals(
            SubscriptionSchedulePolicy.MIN_INTERVAL_MINUTES,
            SubscriptionSchedulePolicy.clampIntervalMinutes(15L),
        )
        assertEquals(
            360L,
            SubscriptionSchedulePolicy.clampIntervalMinutes(360L),
        )
        assertEquals(
            SubscriptionSchedulePolicy.MAX_INTERVAL_MINUTES,
            SubscriptionSchedulePolicy.clampIntervalMinutes(999_999L),
        )
    }

    @Test
    fun plansEnqueuesAndCancellationsForDisabledAndDeletedSubscriptions() {
        val plan =
            SubscriptionSchedulePolicy.plan(
                previouslyScheduledIds = setOf("sub-keep", "sub-disabled", "sub-deleted"),
                requested =
                    listOf(
                        SubscriptionScheduleSpec("sub-keep", autoUpdate = true, intervalMinutes = 60),
                        SubscriptionScheduleSpec("sub-new", autoUpdate = true, intervalMinutes = 5),
                        SubscriptionScheduleSpec("sub-disabled", autoUpdate = false, intervalMinutes = 60),
                    ),
            )

        assertEquals(2, plan.enqueue.size)
        assertEquals("sub-keep", plan.enqueue[0].id)
        assertEquals(60L, plan.enqueue[0].intervalMinutes)
        assertEquals("sub-new", plan.enqueue[1].id)
        assertEquals(15L, plan.enqueue[1].intervalMinutes)

        assertEquals(setOf("sub-disabled", "sub-deleted"), plan.cancelIds)
        assertEquals(setOf("sub-keep", "sub-new"), plan.nextTrackedIds)
        assertTrue(SubscriptionSchedulePolicy.uniqueWorkName("abc").endsWith("abc"))
    }
}
