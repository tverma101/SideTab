package com.sidescreen.app

import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.util.Range

/**
 * One-shot decoder capability probe. AVC-only devices drive the H.264
 * wire-protocol negotiation (the Mac encodes H.264 instead of HEVC).
 *
 * "Has HEVC" means the device has a *usable hardware* HEVC decoder — not merely
 * any decoder that advertises the type. Two classes of device are deliberately
 * routed to H.264 instead:
 *
 *  - **Software-only HEVC** (e.g. Onyx Boox Nova Air C, whose vendor
 *    media_codecs.xml disables HW HEVC): the Google software decoder
 *    (c2.android.hevc / OMX.google.hevc) is far too slow for real-time mirroring.
 *
 *  - **Broken vendor HW HEVC**: Spreadtrum/Unisoc (OMX.sprd.hevc, c2.sprd.*)
 *    advertise a HW HEVC decoder that configures and starts successfully but
 *    never renders decoded frames to the output Surface — the SurfaceView stays
 *    empty and the user sees a black screen (e.g. Yuho Tab 10, SC9863A + PowerVR).
 *
 * Both classes have a working hardware H.264 decoder, so H.264 is the reliable
 * path for them.
 *
 * Every question is answered from ONE cached MediaCodecList enumeration. The
 * host schedules codec negotiation 250 ms after the socket connects and only
 * re-runs it when a later capability advert arrives, so an enumeration on the
 * connect path can consume the entire negotiation window.
 */
object CodecCapabilities {
    /** Decoder-name prefixes whose HEVC implementation is unusable for surface output. */
    private val BROKEN_HEVC_HW_PREFIXES = listOf("omx.sprd.", "c2.sprd.")

    private val PROBED_MIMES = listOf(MediaFormat.MIMETYPE_VIDEO_HEVC, MediaFormat.MIMETYPE_VIDEO_AVC)

    private class DecoderEntry(
        val name: String,
        val mime: String,
        val videoCaps: MediaCodecInfo.VideoCapabilities,
        val isHardware: Boolean,
        val isUsableForOutput: Boolean,
        val isVendor: Boolean,
        val isAlias: Boolean,
        val lowLatency: Boolean,
    )

    private class Inventory(
        val entries: List<DecoderEntry>,
        /** Distinguishes "no usable HEVC" from "the probe could not run at all",
         *  which must keep failing open. */
        val probeFailed: Boolean,
    )

    private val inventory: Inventory by lazy { probeInventory() }

    private fun probeInventory(): Inventory =
        try {
            val entries =
                MediaCodecList(MediaCodecList.ALL_CODECS)
                    .codecInfos
                    .asSequence()
                    .filter { !it.isEncoder }
                    .flatMap { info -> decodersFor(info) }
                    .toList()
            Inventory(entries, probeFailed = false)
        } catch (_: Exception) {
            Inventory(emptyList(), probeFailed = true)
        }

    private fun decodersFor(info: MediaCodecInfo): Sequence<DecoderEntry> =
        PROBED_MIMES.asSequence().mapNotNull { mime ->
            if (info.supportedTypes.none { it.equals(mime, ignoreCase = true) }) return@mapNotNull null
            val caps =
                try {
                    info.getCapabilitiesForType(mime)
                } catch (_: Exception) {
                    null
                } ?: return@mapNotNull null
            val videoCaps = caps.videoCapabilities ?: return@mapNotNull null
            val name = info.name
            val modern = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
            val isHardware = if (modern) info.isHardwareAccelerated else !isSoftwareDecoder(name)
            DecoderEntry(
                name = name,
                mime = mime,
                videoCaps = videoCaps,
                isHardware = isHardware,
                isUsableForOutput = isHardware && !isBrokenHevc(name, mime),
                isVendor = modern && info.isVendor,
                isAlias = modern && info.isAlias,
                lowLatency =
                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
                        runCatching {
                            caps.isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)
                        }.getOrDefault(false),
            )
        }

    /**
     * Name-based hardware/software split for Android 8/9, which have no
     * authoritative classification API. Codec names are mixed case
     * ("OMX.google.h264.decoder"), so the prefixes must match case-insensitively.
     */
    private fun isSoftwareDecoder(name: String): Boolean =
        name.startsWith("c2.android.", ignoreCase = true) || name.startsWith("omx.google.", ignoreCase = true)

    private fun isBrokenHevc(
        name: String,
        mime: String,
    ): Boolean =
        mime.equals(MediaFormat.MIMETYPE_VIDEO_HEVC, ignoreCase = true) &&
            BROKEN_HEVC_HW_PREFIXES.any { name.startsWith(it, ignoreCase = true) }

    /**
     * Resolve every cached answer ahead of time. Call from a background
     * dispatcher at app start so the first connect advertises codec support and
     * decoder limits without a MediaCodecList walk.
     */
    fun warmUp() {
        hasHevcDecoder
        maxDecodeSize(streamMime)
        bestDecoderName(streamMime, 1920, 1200, 60f)
    }

    val hasHevcDecoder: Boolean
        get() {
            val current = inventory
            if (current.probeFailed) return true // fail open: assume HEVC, preserving legacy behavior
            return current.entries.any {
                it.isUsableForOutput && it.mime.equals(MediaFormat.MIMETYPE_VIDEO_HEVC, ignoreCase = true)
            }
        }

    /** Mime the client will ask the Mac to stream: HEVC when usable, else AVC. */
    val streamMime: String
        get() = if (hasHevcDecoder) MediaFormat.MIMETYPE_VIDEO_HEVC else MediaFormat.MIMETYPE_VIDEO_AVC

    private val maxDecodeSizeCache = HashMap<String, Pair<Int, Int>?>()
    private val bestDecoderCache = HashMap<String, String?>()

    /**
     * Upper decode bounds (width × height) of the largest usable *hardware*
     * decoder for [mime] — the software fallback is too slow for real-time
     * mirroring to count as a ceiling. Null when nothing usable exists or the
     * probe fails (legacy behavior: no limit advertised to the Mac).
     * Cached per mime: enumerating MediaCodecList is not cheap and the answer
     * never changes at runtime (same reason hasHevcDecoder is cached).
     */
    fun maxDecodeSize(mime: String): Pair<Int, Int>? =
        synchronized(maxDecodeSizeCache) {
            maxDecodeSizeCache.getOrPut(mime.lowercase()) { probeMaxDecodeSize(mime) }
        }

    private fun probeMaxDecodeSize(mime: String): Pair<Int, Int>? {
        var best: Pair<Int, Int>? = null
        for (entry in inventory.entries) {
            if (!entry.isUsableForOutput || !entry.mime.equals(mime, ignoreCase = true)) continue
            val supported = largestSupportedSize(entry.videoCaps) ?: continue
            val current = best
            if (current == null ||
                supported.first.toLong() * supported.second > current.first.toLong() * current.second
            ) {
                best = supported
            }
        }
        return best
    }

    private fun largestSupportedSize(videoCaps: MediaCodecInfo.VideoCapabilities): Pair<Int, Int>? =
        selectLargestSupportedSize(
            widthBounds = videoCaps.supportedWidths.bounds(),
            heightBounds = videoCaps.supportedHeights.bounds(),
            isSupported = { w, h -> videoCaps.isSizeSupported(w, h) },
        )

    private fun Range<Int>?.bounds(): IntRange? {
        val lower = this?.lower ?: return null
        val upper = this.upper ?: return null
        if (lower < 0 || upper < lower) return null
        return lower..upper
    }

    /**
     * Best decoder name for [mime] at this size, or null to let
     * MediaCodec.createDecoderByType choose. Cached per (mime, size, rate) so a
     * resolution change or a reconnect does not re-walk MediaCodecList.
     * Preference order: hardware that also advertises the target frame rate,
     * then any hardware for the size, then the same two for software.
     */
    fun bestDecoderName(
        mime: String,
        width: Int,
        height: Int,
        targetFrameRate: Float,
    ): String? {
        val key = "${mime.lowercase()}|$width|$height|${targetFrameRate.toInt()}"
        return synchronized(bestDecoderCache) {
            bestDecoderCache.getOrPut(key) { probeBestDecoderName(mime, width, height, targetFrameRate) }
        }
    }

    /**
     * Rank every size-capable decoder. `areSizeAndRateSupported()` is only a
     * codec-standard envelope, not a real-time guarantee, so on Android 10+
     * the manufacturer's performance points and measured achievable rates are
     * stronger evidence. Hardware stays dominant: a software codec makes no
     * rendering-performance promise at all. The first decoder wins a tie.
     */
    private fun probeBestDecoderName(
        mime: String,
        width: Int,
        height: Int,
        targetFrameRate: Float,
    ): String? {
        val targetRate = targetFrameRate.toDouble().coerceAtLeast(30.0)
        val requiredPoint =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                MediaCodecInfo.VideoCapabilities.PerformancePoint(width, height, targetRate.toInt())
            } else {
                null
            }
        var bestName: String? = null
        var bestScore = Int.MIN_VALUE

        for (entry in inventory.entries) {
            if (!entry.mime.equals(mime, ignoreCase = true)) continue
            val caps = entry.videoCaps
            if (!runCatching { caps.isSizeSupported(width, height) }.getOrDefault(false)) continue

            val standardRate = runCatching { caps.areSizeAndRateSupported(width, height, targetRate) }.getOrDefault(false)
            val performanceGuaranteed =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && requiredPoint != null && entry.isHardware) {
                    caps.supportedPerformancePoints?.any { it.covers(requiredPoint) }
                } else {
                    null
                }
            val achievable =
                runCatching { caps.getAchievableFrameRatesFor(width, height)?.upper }
                    .getOrNull()
                    ?.let { it >= targetRate }

            var score = if (entry.isHardware) 1_000 else 0
            if (performanceGuaranteed == true) score += 400
            if (achievable == true) score += 250
            if (standardRate) score += 100
            if (entry.lowLatency) score += 80
            if (entry.isVendor) score += 20
            if (entry.isAlias) score -= 5

            if (score > bestScore) {
                bestScore = score
                bestName = entry.name
            }
        }
        return bestName
    }
}

/**
 * Dimensions a decoder advertises are per-dimension maxima, so a candidate has
 * to come from a small ladder rather than from combining two independent upper
 * bounds.
 */
private val SIZE_ALIGNMENTS = intArrayOf(16, 8)

/** Common desktop capture widths/heights, tried largest first. */
private val COMMON_SIZES = intArrayOf(3840, 2560, 2160, 1920, 1600, 1440, 1280, 1080, 960, 720, 640, 320)

/**
 * Largest advertised size this decoder actually accepts.
 *
 * VideoCapabilities.supportedWidths / supportedHeights are INDEPENDENT
 * per-dimension maxima: a decoder advertising width≤1920 and height≤2160 does
 * not imply 1920×2160 works. Advertising that synthesized rectangle to the Mac
 * produces the exact black screen the limit exists to prevent, so each
 * candidate is validated against the real capability surface before it can be
 * returned.
 */
internal fun selectLargestSupportedSize(
    widthBounds: IntRange?,
    heightBounds: IntRange?,
    isSupported: (Int, Int) -> Boolean,
): Pair<Int, Int>? {
    val widths = widthBounds ?: return null
    val heights = heightBounds ?: return null
    if (widths.isEmpty() || heights.isEmpty()) return null
    for (w in sizeCandidates(widths)) {
        for (h in sizeCandidates(heights)) {
            if (isSupported(w, h)) return w to h
        }
    }
    return null
}

private fun sizeCandidates(bounds: IntRange): List<Int> {
    val candidates = LinkedHashSet<Int>()
    val upper = bounds.last
    candidates += upper
    // Decoders commonly support exactly half of the height they advertise
    // (2160 advertised, 1080 real), which is where a synthesized pair fails.
    if (upper / 2 in bounds) candidates += upper / 2
    for (alignment in SIZE_ALIGNMENTS) {
        val aligned = upper - (upper % alignment)
        if (aligned in bounds) candidates += aligned
    }
    for (size in COMMON_SIZES) {
        if (size in bounds) candidates += size
    }
    return candidates.sortedDescending()
}
