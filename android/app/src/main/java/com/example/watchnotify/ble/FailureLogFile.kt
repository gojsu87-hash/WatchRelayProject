package com.example.watchnotify.ble

import android.content.Context
import android.util.AtomicFile
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

internal object FailureLogFile {
    private const val FILE_NAME = "failure-logs.log"
    private const val RETENTION_MS = 24 * 60 * 60 * 1000L
    private const val MAX_FILE_BYTES = 2 * 1024 * 1024L

    @Synchronized
    fun append(
        context: Context,
        timestamp: Long,
        source: String,
        message: String,
        recordId: String = UUID.randomUUID().toString()
    ) {
        val file = File(context.filesDir, FILE_NAME)
        val cutoff = System.currentTimeMillis() - RETENTION_MS
        if (timestamp < cutoff) return
        val retained = if (file.exists()) {
            file.useLines { lines ->
                lines.filter { line ->
                    val recordTime = line.substringBefore('\t').toLongOrNull()
                    recordTime != null && recordTime >= cutoff
                }.toList()
            }
        } else {
            emptyList()
        }
        val duplicateExists = retained.any { line ->
            runCatching {
                JSONObject(line.substringAfter('\t')).optString("id") == recordId
            }.getOrDefault(false)
        }
        if (duplicateExists) {
            writeAtomically(
                file,
                retained.joinToString(separator = "\n", postfix = if (retained.isEmpty()) "" else "\n")
            )
            return
        }

        val record = JSONObject()
            .put("id", recordId)
            .put("timestamp", timestamp)
            .put("source", source.take(100))
            .put(
                "message",
                message.replace('\n', ' ').replace('\r', ' ').replace('\t', ' ').take(2_000)
            )
            .toString()
        val newLine = "$timestamp\t$record"
        val maxBytes = (
            MAX_FILE_BYTES - newLine.toByteArray(Charsets.UTF_8).size - 1
            ).coerceAtLeast(0)
        val keptLines = ArrayDeque<String>()
        var retainedBytes = 0L
        for (line in retained.asReversed()) {
            val lineBytes = line.toByteArray(Charsets.UTF_8).size + 1L
            if (retainedBytes + lineBytes > maxBytes) break
            keptLines.addFirst(line)
            retainedBytes += lineBytes
        }
        writeAtomically(
            file,
            (keptLines + newLine).joinToString(separator = "\n", postfix = "\n")
        )
    }

    private fun writeAtomically(file: File, contents: String) {
        val atomicFile = AtomicFile(file)
        var output: FileOutputStream? = null
        try {
            output = atomicFile.startWrite()
            output.write(contents.toByteArray(Charsets.UTF_8))
            atomicFile.finishWrite(output)
        } catch (e: Exception) {
            output?.let(atomicFile::failWrite)
            throw e
        }
    }
}
