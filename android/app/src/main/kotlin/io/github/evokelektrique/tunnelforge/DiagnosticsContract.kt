package io.github.evokelektrique.tunnelforge

/** Method channel contract for persisted diagnostics logs and crash artifacts. */
object DiagnosticsContract {
    const val METHOD_CHANNEL = "tunnel_forge/diagnostics"

    const val APPEND_LOGS = "appendLogs"
    const val READ_LOG_TAIL = "readLogTail"
    const val EXPORT_LOGS = "exportLogs"
    const val HAS_TOMBSTONE = "hasTombstone"
    const val CLEAR_LOGS = "clearLogs"

    const val ARG_TS = "ts"
    const val ARG_LEVEL = "level"
    const val ARG_SOURCE = "source"
    const val ARG_TAG = "tag"
    const val ARG_MESSAGE = "message"
    const val ARG_MAX_LINES = "maxLines"
    const val ARG_INCLUDE_TOMBSTONE = "includeTombstone"
}
