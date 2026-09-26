package com.sidescreen.app

/** Separates local prerequisites from a Mac server that has not been probed yet. */
internal enum class ConnectionReadinessState {
    LOCAL_SETUP_REQUIRED,
    SERVER_UNCHECKED,
    SERVER_UNAVAILABLE,
    READY,
}

internal object ConnectionReadinessPolicy {
    fun evaluate(
        localPrerequisitesReady: Boolean,
        macServerAvailable: Boolean?,
    ): ConnectionReadinessState =
        when {
            !localPrerequisitesReady -> ConnectionReadinessState.LOCAL_SETUP_REQUIRED
            macServerAvailable == true -> ConnectionReadinessState.READY
            macServerAvailable == false -> ConnectionReadinessState.SERVER_UNAVAILABLE
            else -> ConnectionReadinessState.SERVER_UNCHECKED
        }
}
