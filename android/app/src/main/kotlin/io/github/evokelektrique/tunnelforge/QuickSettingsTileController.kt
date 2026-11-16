package io.github.evokelektrique.tunnelforge

import android.content.ComponentName
import android.content.Context
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

internal data class QuickSettingsStrings(
    val defaultLabel: String,
    val noProfile: String,
    val connected: String,
    val connecting: String,
    val waitingForNetwork: String,
    val reconnecting: String,
) {
    companion object {
        fun fromContext(context: Context): QuickSettingsStrings =
            QuickSettingsStrings(
                defaultLabel = context.getString(R.string.qs_tile_label),
                noProfile = context.getString(R.string.qs_tile_no_profile),
                connected = context.getString(R.string.qs_tile_connected),
                connecting = context.getString(R.string.qs_tile_connecting),
                waitingForNetwork = context.getString(R.string.qs_tile_waiting_network),
                reconnecting = context.getString(R.string.qs_tile_reconnecting),
            )
    }
}

internal data class QuickSettingsTilePresentation(
    val state: Int,
    val label: String,
    val subtitle: String,
    val stateDescription: String,
)

/** Computes Quick Settings tile state and triggers Android SystemUI tile refreshes. */
internal object QuickSettingsTileController {
    @Volatile
    private var appContext: Context? = null

    fun init(context: Context) {
        appContext = context.applicationContext
    }

    fun requestUpdate(context: Context? = appContext) {
        val ctx = context?.applicationContext ?: return
        try {
            TileService.requestListeningState(
                ctx,
                ComponentName(ctx, TunnelQuickSettingsTileService::class.java),
            )
        } catch (e: Exception) {
            AppLog.w(TAG, "requestListeningState failed: ${e.message}")
        }
    }

    fun activeRuntimeSnapshot(): Map<String, Any?>? =
        TunnelVpnService.runtimeSnapshot() ?: ProxyTunnelService.runtimeSnapshot()

    fun isActiveTunnelState(state: String?): Boolean =
        state == VpnContract.TUNNEL_CONNECTED ||
            state == VpnContract.TUNNEL_CONNECTING ||
            state == VpnContract.TUNNEL_WAITING_FOR_NETWORK ||
            state == VpnContract.TUNNEL_RECONNECTING

    fun resolvePresentation(
        runtimeSnapshot: Map<String, Any?>?,
        storedConfig: TunnelLaunchConfig?,
        strings: QuickSettingsStrings,
    ): QuickSettingsTilePresentation {
        val tunnelState = runtimeSnapshot?.get(VpnContract.ARG_TUNNEL_STATE) as? String
        val active = isActiveTunnelState(tunnelState)
        val profileLabel = storedConfig?.displayLabel?.takeIf { it.isNotBlank() }

        if (active) {
            val statusText =
                when (tunnelState) {
                    VpnContract.TUNNEL_CONNECTED -> strings.connected
                    VpnContract.TUNNEL_WAITING_FOR_NETWORK -> strings.waitingForNetwork
                    VpnContract.TUNNEL_RECONNECTING -> strings.reconnecting
                    else -> strings.connecting
                }
            val subtitle = profileLabel ?: statusText
            val stateDescription =
                if (profileLabel != null) "$statusText · $profileLabel" else statusText
            return QuickSettingsTilePresentation(
                state = Tile.STATE_ACTIVE,
                label = strings.defaultLabel,
                subtitle = subtitle,
                stateDescription = stateDescription,
            )
        }

        if (profileLabel == null) {
            return QuickSettingsTilePresentation(
                state = Tile.STATE_UNAVAILABLE,
                label = strings.defaultLabel,
                subtitle = strings.noProfile,
                stateDescription = strings.noProfile,
            )
        }

        return QuickSettingsTilePresentation(
            state = Tile.STATE_INACTIVE,
            label = strings.defaultLabel,
            subtitle = profileLabel,
            stateDescription = profileLabel,
        )
    }

    private const val TAG = "QuickSettingsTile"
}
