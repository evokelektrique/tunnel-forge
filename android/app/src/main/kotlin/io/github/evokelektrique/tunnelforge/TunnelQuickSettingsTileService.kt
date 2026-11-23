package io.github.evokelektrique.tunnelforge

import android.Manifest
import android.annotation.SuppressLint
import android.app.ForegroundServiceStartNotAllowedException
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.net.VpnService
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/** Android Quick Settings tile toggling the tunnel using the app's current profile. */
class TunnelQuickSettingsTileService : TileService() {

    override fun onStartListening() {
        super.onStartListening()
        refreshTile()
    }

    override fun onClick() {
        super.onClick()
        if (isLocked) {
            unlockAndRun { handleTileClick() }
            return
        }
        handleTileClick()
    }

    private fun handleTileClick() {
        val activeRuntime = QuickSettingsTileController.activeRuntimeSnapshot()
        val activeState = activeRuntime?.get(VpnContract.ARG_TUNNEL_STATE) as? String
        if (QuickSettingsTileController.isActiveTunnelState(activeState)) {
            val mode = activeRuntime?.get(VpnContract.ARG_CONNECTION_MODE) as? String
            val attemptId = activeRuntime?.get(VpnContract.ARG_ATTEMPT_ID) as? String ?: ""
            AppLog.i(TAG, "qs_tile disconnect mode=${mode ?: "all"} attempt=$attemptId")
            TunnelServiceLauncher.stop(this, mode, attemptId)
            refreshTile()
            return
        }

        val config = QuickSettingsConfigStore.create(this).load()
        if (config == null) {
            AppLog.d(TAG, "qs_tile click ignored: no current profile")
            refreshTile()
            return
        }

        if (needsAppInteractionForConnect(config)) {
            AppLog.i(TAG, "qs_tile opening app for permission/credentials profile=${config.profileId}")
            launchAppToConnect()
            return
        }

        val attemptId = "qs-${System.currentTimeMillis().toString(36)}"
        AppLog.i(
            TAG,
            "qs_tile connect attempt=$attemptId profile=${config.profileId} mode=${config.connectionMode}",
        )
        TunnelServiceLauncher.prepareForStart(config.connectionMode)
        val serviceIntent = TunnelServiceLauncher.buildStartIntent(this, config, attemptId)
        try {
            TunnelServiceLauncher.startForegroundWorkerService(this, serviceIntent)
            refreshTile(optimisticConnecting = true, config = config)
        } catch (e: ForegroundServiceStartNotAllowedException) {
            AppLog.w(TAG, "qs_tile foreground service blocked; opening app", e)
            launchAppToConnect()
        } catch (e: SecurityException) {
            AppLog.w(TAG, "qs_tile start rejected; opening app", e)
            launchAppToConnect()
        } catch (e: RuntimeException) {
            AppLog.e(TAG, "qs_tile start failed", e)
            launchAppToConnect()
        }
    }

    private fun needsAppInteractionForConnect(config: TunnelLaunchConfig): Boolean {
        if (config.secretsMissing) return true
        if (config.connectionMode == VpnContract.MODE_VPN_TUNNEL && VpnService.prepare(this) != null) {
            return true
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            return true
        }
        return false
    }

    @SuppressLint("StartActivityAndCollapseDeprecated")
    private fun launchAppToConnect() {
        val intent =
            Intent(this, MainActivity::class.java).apply {
                action = MainActivity.ACTION_QUICK_SETTINGS_CONNECT
                putExtra(MainActivity.EXTRA_QS_CONNECT_TOKEN, QuickSettingsTileController.issueConnectLaunchToken())
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val pendingIntent =
                PendingIntent.getActivity(
                    this,
                    REQUEST_CODE_LAUNCH_CONNECT,
                    intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
            startActivityAndCollapse(pendingIntent)
        } else {
            // The PendingIntent overload was introduced in API 34.
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }

    private fun refreshTile(
        optimisticConnecting: Boolean = false,
        config: TunnelLaunchConfig? = null,
    ) {
        val tile = qsTile ?: return
        val resolvedConfig = config ?: QuickSettingsConfigStore.create(this).load()
        val runtime =
            if (optimisticConnecting) {
                mapOf(VpnContract.ARG_TUNNEL_STATE to VpnContract.TUNNEL_CONNECTING)
            } else {
                QuickSettingsTileController.activeRuntimeSnapshot()
            }
        val presentation =
            QuickSettingsTileController.resolvePresentation(
                runtimeSnapshot = runtime,
                storedConfig = resolvedConfig,
                strings = QuickSettingsStrings.fromContext(this),
            )
        tile.state = presentation.state
        tile.label = presentation.label
        tile.subtitle = presentation.subtitle
        tile.stateDescription = presentation.stateDescription
        tile.icon = Icon.createWithResource(this, R.drawable.ic_qs_tunnel)
        tile.updateTile()
    }

    companion object {
        private const val TAG = "TunnelQSTile"
        private const val REQUEST_CODE_LAUNCH_CONNECT = 0x5153
    }
}
