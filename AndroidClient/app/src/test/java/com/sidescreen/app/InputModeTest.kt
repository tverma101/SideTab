package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class InputModeTest {
    // MARK: - Persistence round trip

    @Test
    fun everyModeRoundTripsThroughItsPersistedName() {
        for (mode in InputMode.values()) {
            assertEquals(mode, InputMode.fromName(mode.name))
        }
    }

    /** A build that renames or removes a mode must not read as a valid one. */
    @Test
    fun unknownOrMissingNamesFallBackToBothRatherThanFailing() {
        assertEquals(InputMode.BOTH, InputMode.fromName(null))
        assertEquals(InputMode.BOTH, InputMode.fromName(""))
        assertEquals(InputMode.BOTH, InputMode.fromName("pen"))
        assertEquals(InputMode.BOTH, InputMode.fromName("REMOVED_MODE"))
    }

    // MARK: - Mode semantics

    @Test
    fun eachModeForwardsExactlyTheIntendedChannels() {
        assertTrue(InputMode.BOTH.sendsTouch)
        assertTrue(InputMode.BOTH.sendsStylus)

        assertTrue(InputMode.TOUCH_ONLY.sendsTouch)
        assertFalse(InputMode.TOUCH_ONLY.sendsStylus)

        assertFalse(InputMode.PEN_ONLY.sendsTouch)
        assertTrue(InputMode.PEN_ONLY.sendsStylus)

        assertFalse(InputMode.OFF.sendsTouch)
        assertFalse(InputMode.OFF.sendsStylus)
    }

    // MARK: - Filtering

    @Test
    fun bothModeForwardsEverythingAndKeepsPalmRejection() {
        assertTrue(InputFilterPolicy.shouldForward(InputMode.BOTH, hasStylusPointer = true, stylusOwnsGesture = false))
        assertTrue(InputFilterPolicy.shouldForward(InputMode.BOTH, hasStylusPointer = false, stylusOwnsGesture = false))
        // The ownership branch performs palm rejection, so the event must reach
        // it rather than being dropped here.
        assertTrue(InputFilterPolicy.shouldForward(InputMode.BOTH, hasStylusPointer = false, stylusOwnsGesture = true))
    }

    @Test
    fun offModeForwardsNothing() {
        for (stylus in listOf(true, false)) {
            for (owns in listOf(true, false)) {
                assertFalse(
                    InputFilterPolicy.shouldForward(InputMode.OFF, hasStylusPointer = stylus, stylusOwnsGesture = owns),
                )
            }
        }
    }

    @Test
    fun touchOnlyForwardsFingersAndDropsThePen() {
        assertTrue(InputFilterPolicy.shouldForward(InputMode.TOUCH_ONLY, hasStylusPointer = false, stylusOwnsGesture = false))
        assertFalse(InputFilterPolicy.shouldForward(InputMode.TOUCH_ONLY, hasStylusPointer = true, stylusOwnsGesture = false))
    }

    /**
     * The bug this policy exists to prevent. A disabled pen that still owned the
     * sequence made the ownership branch discard every companion finger, so a
     * pen resting on the tablet silenced touch for the whole contact.
     */
    @Test
    fun aDisabledPenCannotBlockFingers() {
        assertFalse(
            InputFilterPolicy.shouldForward(InputMode.TOUCH_ONLY, hasStylusPointer = false, stylusOwnsGesture = true),
        )
        assertFalse(
            InputFilterPolicy.shouldForward(InputMode.OFF, hasStylusPointer = false, stylusOwnsGesture = true),
        )
    }

    @Test
    fun penOnlyForwardsThePenIncludingTheStrokeThatStartsIt() {
        // Ownership is INVALID on the first ACTION_DOWN, so a rule that also
        // required prior ownership would drop every pen stroke at its first
        // sample and the pen would appear dead.
        assertTrue(InputFilterPolicy.shouldForward(InputMode.PEN_ONLY, hasStylusPointer = true, stylusOwnsGesture = false))
        assertTrue(InputFilterPolicy.shouldForward(InputMode.PEN_ONLY, hasStylusPointer = true, stylusOwnsGesture = true))
        assertFalse(InputFilterPolicy.shouldForward(InputMode.PEN_ONLY, hasStylusPointer = false, stylusOwnsGesture = false))
    }

    @Test
    fun hoverIsSuppressedExactlyWhenThePenIs() {
        assertTrue(InputFilterPolicy.sendsStylusHover(InputMode.BOTH))
        assertTrue(InputFilterPolicy.sendsStylusHover(InputMode.PEN_ONLY))
        assertFalse(InputFilterPolicy.sendsStylusHover(InputMode.TOUCH_ONLY))
        assertFalse(InputFilterPolicy.sendsStylusHover(InputMode.OFF))
    }

    // MARK: - The mode is a total function

    /**
     * Every combination must resolve without throwing. `handleTouch` runs on the
     * UI thread inside a MotionEvent dispatch, so an unexpected input here would
     * crash the app mid-gesture.
     */
    @Test
    fun everyModeAndEventShapeCombinationResolves() {
        for (mode in InputMode.values()) {
            for (hasStylus in listOf(true, false)) {
                for (owns in listOf(true, false)) {
                    InputFilterPolicy.shouldForward(mode, hasStylus, owns)
                    InputFilterPolicy.sendsStylusHover(mode)
                }
            }
        }
    }
}
