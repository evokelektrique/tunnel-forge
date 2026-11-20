package io.github.evokelektrique.tunnelforge

import android.content.res.Configuration
import android.graphics.Color
import android.util.TypedValue
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SplashThemeTest {
    @Test
    fun splashBackgroundMatchesLightAndDarkResources() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        for ((nightMode, expectedColor) in listOf(
            Configuration.UI_MODE_NIGHT_NO to Color.rgb(209, 250, 229),
            Configuration.UI_MODE_NIGHT_YES to Color.rgb(14, 17, 20),
        )) {
            val configuration = Configuration(context.resources.configuration).apply {
                val baseUiMode = uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()
                uiMode = baseUiMode or nightMode
            }
            val themedContext = context.createConfigurationContext(configuration)
            val theme = themedContext.resources.newTheme().apply {
                applyStyle(R.style.LaunchTheme, true)
            }
            val value = TypedValue()
            assertTrue(theme.resolveAttribute(android.R.attr.windowSplashScreenBackground, value, true))
            assertEquals("Android 12+ splash nightMode=$nightMode", expectedColor, value.data)
            assertTrue(theme.resolveAttribute(android.R.attr.windowSplashScreenAnimatedIcon, value, true))
            assertEquals(R.drawable.android12splash, value.resourceId)
        }
    }
}
