package io.github.evokelektrique.tunnelforge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

class AppLocaleSupportTest {

    private fun resolveAppMainDir(): File {
        val cwd = File(System.getProperty("user.dir") ?: ".")
        val candidates = listOf(
            File(cwd, "src/main"),
            File(cwd, "app/src/main"),
            File(cwd, "android/app/src/main"),
        )
        return candidates.first { it.isDirectory }
    }

    private fun parseStringsXml(file: File): Map<String, Boolean> {
        val doc = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file)
        val nodes = doc.getElementsByTagName("string")
        val out = linkedMapOf<String, Boolean>()
        for (i in 0 until nodes.length) {
            val element = nodes.item(i) as Element
            val name = element.getAttribute("name")
            val translatable = element.getAttribute("translatable") != "false"
            out[name] = translatable
        }
        return out
    }

    @Test
    fun normalizeLanguageTagHandlesSystemBlankAndRegions() {
        assertNull(AppLocaleSupport.normalizeLanguageTag(null))
        assertNull(AppLocaleSupport.normalizeLanguageTag(""))
        assertNull(AppLocaleSupport.normalizeLanguageTag("  "))
        assertNull(AppLocaleSupport.normalizeLanguageTag("system"))
        assertNull(AppLocaleSupport.normalizeLanguageTag("SYSTEM"))
        assertEquals("fa", AppLocaleSupport.normalizeLanguageTag("fa"))
        assertEquals("pt-BR", AppLocaleSupport.normalizeLanguageTag(" pt_BR "))
        assertEquals("zh-Hant-TW", AppLocaleSupport.normalizeLanguageTag("zh_Hant_TW"))
    }

    @Test
    fun persianStringsXmlMatchesAllTranslatableEnglishKeys() {
        val mainDir = resolveAppMainDir()
        val enStrings = parseStringsXml(File(mainDir, "res/values/strings.xml"))
        val faStrings = parseStringsXml(File(mainDir, "res/values-fa/strings.xml"))

        val expectedTranslatable = enStrings.filterValues { it }.keys
        assertTrue(expectedTranslatable.isNotEmpty())
        assertEquals(expectedTranslatable, faStrings.keys)
        for ((key, translatable) in enStrings) {
            if (key.startsWith("qs_tile_")) {
                assertFalse("Quick Settings key $key must stay untranslatable", translatable)
            }
        }
    }

    @Test
    fun quickSettingsTileUsesEnglishContext() {
        val mainDir = resolveAppMainDir()
        val controllerFile =
            File(mainDir, "kotlin/io/github/evokelektrique/tunnelforge/QuickSettingsTileController.kt")
        val source = controllerFile.readText()
        assertTrue(source.contains("AppLocaleSupport.englishContext(context)"))
        assertFalse(source.contains("AppLocaleSupport.localizedContext(context)"))
    }

    @Test
    fun tunnelServicesKeepCurrentTunnelDetailDecoupledFromLocalizedResources() {
        val mainDir = resolveAppMainDir()
        val kotlinDir = File(mainDir, "kotlin/io/github/evokelektrique/tunnelforge")
        val serviceFiles = listOf(
            File(kotlinDir, "TunnelVpnService.kt"),
            File(kotlinDir, "ProxyTunnelService.kt"),
        )
        val forbiddenPattern = Regex("""currentTunnelDetail\s*=\s*(?:AppLocaleSupport\.)?getString\(""")
        for (file in serviceFiles) {
            val source = file.readText()
            assertFalse(
                "Localized string assigned to currentTunnelDetail in ${file.name}",
                forbiddenPattern.containsMatchIn(source),
            )
        }
    }

    @Test
    fun localizedContextAppliesStoredOrSystemLocaleSynchronouslyAndRefreshesNotifications() {
        val mainDir = resolveAppMainDir()
        val kotlinDir = File(mainDir, "kotlin/io/github/evokelektrique/tunnelforge")
        val localeSupportSource = File(kotlinDir, "AppLocaleSupport.kt").readText()

        assertFalse(
            "localizedContext must not short-circuit on Android 13+ while LocaleManager propagates asynchronously",
            Regex("""fun\s+localizedContext[\s\S]*?TIRAMISU""").containsMatchIn(localeSupportSource),
        )
        assertTrue(localeSupportSource.contains("Resources.getSystem().configuration.locales"))
        assertTrue(localeSupportSource.contains("refreshActiveNotifications(context)"))
        assertTrue(localeSupportSource.contains("TunnelVpnService.refreshNotificationLanguage(appContext)"))
        assertTrue(localeSupportSource.contains("ProxyTunnelService.refreshNotificationLanguage(appContext)"))
        assertTrue(localeSupportSource.contains("TunnelDisconnectNotification.refreshActiveNotifications(appContext)"))
        assertTrue(localeSupportSource.contains("SubscriptionNotification.refreshActiveNotifications(appContext)"))
    }

    @Test
    fun alertAndSubscriptionNotificationsRefreshSilentlyInPlace() {
        val mainDir = resolveAppMainDir()
        val kotlinDir = File(mainDir, "kotlin/io/github/evokelektrique/tunnelforge")
        val disconnectSource = File(kotlinDir, "TunnelDisconnectNotification.kt").readText()
        val subscriptionSource = File(kotlinDir, "SubscriptionNotification.kt").readText()

        assertTrue(disconnectSource.contains("fun refreshActiveNotifications(context: Context)"))
        assertTrue(disconnectSource.contains("setSilent(true).setOnlyAlertOnce(true)"))
        assertTrue(subscriptionSource.contains("fun refreshActiveNotifications(context: Context)"))
        assertTrue(subscriptionSource.contains("setSilent(true).setOnlyAlertOnce(true)"))
    }
}
