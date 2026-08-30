package com.sidescreen.app

enum class ConnectionMode {
    USB,
    WIRELESS,
    ;

    val displayName: String
        get() = if (this == USB) "USB" else "Wireless"

    internal fun wireValue(): Int = if (this == USB) 0 else 1

    companion object {
        fun fromName(name: String?): ConnectionMode = values().firstOrNull { it.name == name } ?: USB

        internal fun fromWireValue(value: Int): ConnectionMode? =
            values().firstOrNull { it.wireValue() == value }
    }
}
