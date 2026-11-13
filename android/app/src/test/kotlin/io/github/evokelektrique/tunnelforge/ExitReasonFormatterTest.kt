package io.github.evokelektrique.tunnelforge

import android.app.ApplicationExitInfo
import android.util.Log
import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.ZoneOffset

class ExitReasonFormatterTest {
    @Test
    fun mapsExitReasonConstantsAndPriorities() {
        assertEquals("CRASH", ExitReasonFormatter.reasonName(ApplicationExitInfo.REASON_CRASH))
        assertEquals("CRASH_NATIVE", ExitReasonFormatter.reasonName(ApplicationExitInfo.REASON_CRASH_NATIVE))
        assertEquals("ANR", ExitReasonFormatter.reasonName(ApplicationExitInfo.REASON_ANR))
        assertEquals("USER_REQUESTED", ExitReasonFormatter.reasonName(ApplicationExitInfo.REASON_USER_REQUESTED))
        assertEquals("USER_STOPPED", ExitReasonFormatter.reasonName(ApplicationExitInfo.REASON_USER_STOPPED))

        assertEquals(Log.INFO, ExitReasonFormatter.priorityForReason(ApplicationExitInfo.REASON_USER_REQUESTED))
        assertEquals(Log.INFO, ExitReasonFormatter.priorityForReason(ApplicationExitInfo.REASON_USER_STOPPED))
        assertEquals(Log.WARN, ExitReasonFormatter.priorityForReason(ApplicationExitInfo.REASON_CRASH_NATIVE))
    }

    @Test
    fun formatsPreviousExitSummaryLine() {
        val line =
            ExitReasonFormatter.formatSummary(
                reason = ApplicationExitInfo.REASON_CRASH_NATIVE,
                status = 11,
                description = "SIGSEGV",
                timestampMs = 1_700_000_000_000L,
                importance = 100,
                pssKb = 12345,
                rssKb = 23456,
                zoneId = ZoneOffset.UTC,
            )

        assertEquals(
            "previous exit: reason=CRASH_NATIVE status=11 desc=SIGSEGV at 2023-11-14T22:13:20.000+0000 importance=100 pss=12345KB rss=23456KB",
            line,
        )
    }
}
