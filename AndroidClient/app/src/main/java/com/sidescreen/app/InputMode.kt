package com.sidescreen.app

/**
 * Which input sources the tablet forwards to the Mac.
 *
 * Modelled as one enum rather than a pair of booleans so the illegal state — a
 * "pen only" flag disagreeing with independently-set enable flags — cannot be
 * represented or stored. Persisted by name, like [ConnectionMode].
 */
enum class InputMode {
    /** Fingers and S Pen both drive the Mac. */
    BOTH,

    /** Only fingers drive the Mac; the pen is ignored entirely. */
    TOUCH_ONLY,

    /** Only the S Pen drives the Mac; fingers are ignored. */
    PEN_ONLY,

    /** Display-only. Nothing is forwarded, so the Mac keeps no input state. */
    OFF,
    ;

    val sendsTouch: Boolean
        get() = this == BOTH || this == TOUCH_ONLY

    val sendsStylus: Boolean
        get() = this == BOTH || this == PEN_ONLY

    companion object {
        fun fromName(name: String?): InputMode = values().firstOrNull { it.name == name } ?: BOTH
    }
}

/**
 * Pure resolution of a [MotionEvent] against the current [InputMode].
 *
 * Extracted from `MainActivity.handleTouch` so the filtering rules are testable
 * on the JVM. The project has no Robolectric and no instrumentation source set,
 * and `handleTouch`'s classification logic had no coverage at all, which is
 * exactly how a non-obvious bug reached the shipping path: deciding "is this the
 * pen?" before deciding "is the pen allowed?" made a disabled pen an input
 * *blocker* — the pen still claimed pointer ownership, and the ownership branch
 * then discarded every companion finger for the whole contact, so a pen resting
 * on the tablet silenced the touchscreen.
 *
 * Resolving the mode first, before any ownership or predictor state is touched,
 * is what prevents that.
 */
internal object InputFilterPolicy {
    /**
     * Whether `handleTouch` may proceed for this event.
     *
     * @param hasStylusPointer whether any pointer in the event is a pen/eraser.
     * @param stylusOwnsGesture whether a pen already owns the current sequence,
     *   which is what normally performs palm rejection.
     */
    fun shouldForward(
        mode: InputMode,
        hasStylusPointer: Boolean,
        stylusOwnsGesture: Boolean,
    ): Boolean =
        when (mode) {
            InputMode.OFF -> false
            // Unchanged behaviour: the pen-ownership branch below still
            // performs palm rejection, which is correct here.
            InputMode.BOTH -> true
            // Pen ignored. Only pure-finger events pass, and never while a pen
            // owns the sequence — otherwise the pen would keep swallowing
            // fingers even though it is no longer allowed to be sent. The
            // ownership state is cleared by the mid-stream abort instead.
            InputMode.TOUCH_ONLY -> !hasStylusPointer && !stylusOwnsGesture
            // Pen only. Ownership is irrelevant: a pen pointer is exactly what
            // is wanted, whether it starts or continues a stroke.
            InputMode.PEN_ONLY -> hasStylusPointer
        }

    /**
     * Whether a stylus HOVER sample may be sent. Hover has no down/up
     * counterpart, so it needs no terminating event: it is a pure position
     * report that simply stops.
     */
    fun sendsStylusHover(mode: InputMode): Boolean = mode.sendsStylus
}
