package io.github.evokelektrique.tunnelforge

import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MainActivityLifecycleTest {
    @Test
    fun appTracksVisibilityWhileTheActivityIsOpen() {
        ActivityScenario.launch(MainActivity::class.java).use {
            assertTrue(AppForegroundTracker.isForeground())
        }
        assertFalse(AppForegroundTracker.isForeground())
    }
}
