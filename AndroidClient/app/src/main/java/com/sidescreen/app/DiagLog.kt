package com.sidescreen.app

import android.content.Context
import android.util.Log
import java.io.BufferedWriter
import java.io.File
import java.io.FileOutputStream
import java.io.OutputStreamWriter
import java.util.ArrayDeque
import java.util.concurrent.Executors

/**
 * Shared diagnostic file logger for debugging on devices that suppress logcat.
 * File I/O is asynchronous and batched so a reconnect/decoder-log burst does
 * not translate into one open/seek/write/close cycle per message.
 */
object DiagLog {
    private const val TAG = "DiagLog"
    private const val LOG_FILE = "diag.log"
    private const val MAX_LOG_SIZE = 1_048_576L // 1MB
    private const val MAX_PENDING_LINES = 1024
    private const val MAX_BATCH_LINES = 256

    @Volatile
    private var logFile: File? = null

    private val queueLock = Any()
    private val pendingLines = ArrayDeque<String>()
    private var drainScheduled = false

    private val logExecutor =
        Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "DiagLogWriter").apply {
                isDaemon = true
            }
        }

    /** Initialize with app context. Call once from Application.onCreate() or MainActivity. */
    fun init(context: Context) {
        logFile = File(context.filesDir, LOG_FILE)
    }

    fun log(
        tag: String,
        msg: String,
    ) {
        Log.d(tag, msg)
        if (logFile == null) return

        val line = "[${System.currentTimeMillis()}] $tag: $msg\n"
        val shouldSchedule =
            synchronized(queueLock) {
                // Diagnostics must never become an unbounded producer queue.
                // Preserve the newest context during a pathological burst.
                while (pendingLines.size >= MAX_PENDING_LINES) {
                    pendingLines.removeFirst()
                }
                pendingLines.addLast(line)
                if (drainScheduled) {
                    false
                } else {
                    drainScheduled = true
                    true
                }
            }
        if (shouldSchedule) {
            logExecutor.execute(::drainLoop)
        }
    }

    private fun drainLoop() {
        while (true) {
            val batch =
                synchronized(queueLock) {
                    if (pendingLines.isEmpty()) {
                        drainScheduled = false
                        return
                    }
                    val count = minOf(MAX_BATCH_LINES, pendingLines.size)
                    ArrayList<String>(count).also { lines ->
                        repeat(count) { lines.add(pendingLines.removeFirst()) }
                    }
                }

            val file = logFile ?: continue
            try {
                rotateIfNeeded(file)
                BufferedWriter(OutputStreamWriter(FileOutputStream(file, true), Charsets.UTF_8)).use { writer ->
                    for (line in batch) writer.write(line)
                    writer.flush()
                }
            } catch (_: Exception) {
                // Diagnostics are best-effort and must never affect streaming.
            }
        }
    }

    private fun rotateIfNeeded(file: File) {
        if (!file.exists() || file.length() <= MAX_LOG_SIZE) return
        val backup = File(file.parentFile, "diag.log.old")
        backup.delete()
        file.renameTo(backup)
    }
}
