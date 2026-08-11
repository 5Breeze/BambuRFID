package com.bamburfid.app

import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.MifareClassic
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.StandardCharsets
import java.util.concurrent.Executors
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

class MainActivity : FlutterActivity(), NfcAdapter.ReaderCallback {
    private val methodChannelName = "bambu_rfid/nfc"
    private val eventChannelName = "bambu_rfid/nfc_events"

    private var nfcAdapter: NfcAdapter? = null
    @Volatile private var eventSink: EventChannel.EventSink? = null
    @Volatile private var readerRequested = false

    // Reader callbacks can arrive while the previous MIFARE transaction is
    // still finishing. The old implementation simply dropped those callbacks.
    // Keep a latest-tag queue and drain it on one worker instead, so rapid spool
    // changes cannot permanently leave the UI showing stale data.
    private val queueLock = Any()
    private val refreshLock = Any()
    private val readExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var workerRunning = false
    private var pendingTag: Tag? = null
    private var refreshPending = false

    private var lastDeliveredUid = ""
    private var lastDeliveredAt = 0L
    private var scanSequence = 0L
    private var completedTransactions = 0

    private val preferences by lazy {
        getSharedPreferences("bambu_rfid_preferences", MODE_PRIVATE)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        nfcAdapter = NfcAdapter.getDefaultAdapter(this)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isAvailable" -> result.success(nfcAdapter != null)
                    "isEnabled" -> result.success(nfcAdapter?.isEnabled == true)
                    "start" -> {
                        enableReader()
                        result.success(null)
                    }
                    "stop" -> {
                        disableReader()
                        result.success(null)
                    }
                    "getPreferredLanguage" -> {
                        result.success(preferences.getString("language", null))
                    }
                    "setPreferredLanguage" -> {
                        val language = call.argument<String>("language")
                        if (language == "zh" || language == "en") {
                            preferences.edit().putString("language", language).apply()
                            result.success(null)
                        } else {
                            result.error(
                                "INVALID_LANGUAGE",
                                "language must be zh or en",
                                null
                            )
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
    }

    override fun onDestroy() {
        disableReader()
        readExecutor.shutdownNow()
        super.onDestroy()
    }

    private fun enableReader() {
        readerRequested = true
        mainHandler.post { enableReaderNow() }
    }

    private fun enableReaderNow() {
        if (!readerRequested) return
        val adapter = nfcAdapter ?: return
        if (!adapter.isEnabled) return
        try {
            adapter.enableReaderMode(
                this,
                this,
                NfcAdapter.FLAG_READER_NFC_A or NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK,
                Bundle().apply {
                    putInt(NfcAdapter.EXTRA_READER_PRESENCE_CHECK_DELAY, 125)
                }
            )
        } catch (_: Exception) {
        }
    }

    private fun disableReader() {
        readerRequested = false
        synchronized(queueLock) {
            pendingTag = null
        }
        mainHandler.post {
            try {
                nfcAdapter?.disableReaderMode(this)
            } catch (_: Exception) {
            }
        }
    }

    private fun scheduleReaderRefresh(delayMs: Long = 180L) {
        synchronized(refreshLock) {
            if (refreshPending) return
            refreshPending = true
        }

        mainHandler.postDelayed({
            synchronized(refreshLock) { refreshPending = false }
            if (!readerRequested) return@postDelayed

            val busy = synchronized(queueLock) { workerRunning }
            if (busy) {
                scheduleReaderRefresh(120L)
                return@postDelayed
            }

            try {
                nfcAdapter?.disableReaderMode(this)
            } catch (_: Exception) {
            }
            enableReaderNow()
        }, delayMs)
    }

    override fun onTagDiscovered(tag: Tag) {
        if (!readerRequested) return

        var shouldLaunchWorker = false
        synchronized(queueLock) {
            // Latest wins. This matters when A is still being read and the user
            // already presents B; B is retained instead of silently discarded.
            pendingTag = tag
            if (!workerRunning) {
                workerRunning = true
                shouldLaunchWorker = true
            }
        }

        if (shouldLaunchWorker) {
            readExecutor.execute { drainTagQueue() }
        }
    }

    private fun drainTagQueue() {
        while (true) {
            val tag = synchronized(queueLock) {
                val next = pendingTag
                pendingTag = null
                if (next == null) {
                    workerRunning = false
                    return
                }
                next
            }

            if (!readerRequested) continue
            processTag(tag)
        }
    }

    private fun processTag(tag: Tag) {
        val uidHex = tag.id.toHex()
        val now = System.currentTimeMillis()

        // Reader-mode refreshes can rediscover a tag that is still physically
        // held against the phone. Suppress only that immediate duplicate; a
        // different UID is never blocked by this debounce.
        if (uidHex == lastDeliveredUid && now - lastDeliveredAt < 700L) {
            return
        }

        emit(mapOf("event" to "reading", "uid" to uidHex))

        var hadError = false
        try {
            val payload = readBambuTagWithRetry(tag, attempts = 3)
            lastDeliveredUid = uidHex
            lastDeliveredAt = System.currentTimeMillis()
            scanSequence += 1
            emit(
                payload + mapOf(
                    "event" to "tag",
                    "scanSequence" to scanSequence,
                )
            )
        } catch (e: Exception) {
            hadError = true
            emit(
                mapOf(
                    "event" to "error",
                    "errorCode" to friendlyErrorCode(e),
                    "message" to friendlyError(e),
                    "uid" to uidHex,
                )
            )
        } finally {
            completedTransactions += 1

            // Periodically rebuild ReaderMode and always rebuild it after a
            // failed transaction. This clears stale NFC stack state observed on
            // some Android devices during repeated MIFARE Classic scans.
            if (hadError || completedTransactions >= 4) {
                completedTransactions = 0
                scheduleReaderRefresh(if (hadError) 160L else 240L)
            }
        }
    }

    private fun readBambuTagWithRetry(tag: Tag, attempts: Int): Map<String, Any?> {
        var lastError: Exception? = null
        repeat(attempts) { attempt ->
            try {
                return readBambuTag(tag)
            } catch (e: Exception) {
                lastError = e
                val message = e.message.orEmpty()
                if (
                    message.contains("MIFARE_CLASSIC_UNSUPPORTED") ||
                    message.contains("UNEXPECTED_UID_LENGTH")
                ) {
                    throw e
                }
                if (attempt < attempts - 1) {
                    try {
                        Thread.sleep(75L + attempt * 45L)
                    } catch (_: InterruptedException) {
                        Thread.currentThread().interrupt()
                        throw e
                    }
                }
            }
        }
        throw lastError ?: IllegalStateException("READ_FAILED")
    }

    private fun readBambuTag(tag: Tag): Map<String, Any?> {
        val mifare = MifareClassic.get(tag)
            ?: throw UnsupportedOperationException("MIFARE_CLASSIC_UNSUPPORTED")

        val uid = tag.id
        if (uid.size != 4) {
            throw IllegalArgumentException("UNEXPECTED_UID_LENGTH")
        }

        val keyA = deriveKeys(uid, "RFID-A\u0000")
        val keyB = deriveKeys(uid, "RFID-B\u0000")
        val blocks = mutableMapOf<Int, ByteArray>()

        try {
            // Keep each low-level operation bounded so a marginal tag cannot
            // hold the read queue indefinitely.
            mifare.timeout = 1100
            mifare.connect()

            val sectorsToRead = minOf(5, mifare.sectorCount)
            for (sector in 0 until sectorsToRead) {
                val authenticated = try {
                    mifare.authenticateSectorWithKeyA(sector, keyA[sector]) ||
                        mifare.authenticateSectorWithKeyB(sector, keyB[sector])
                } catch (_: Exception) {
                    false
                }

                if (!authenticated) {
                    throw SecurityException("AUTH_FAILED_$sector")
                }

                val firstBlock = mifare.sectorToBlock(sector)
                val blockCount = mifare.getBlockCountInSector(sector)
                for (offset in 0 until blockCount - 1) {
                    val absoluteBlock = firstBlock + offset
                    blocks[absoluteBlock] = mifare.readBlock(absoluteBlock)
                }
            }
        } finally {
            try {
                mifare.close()
            } catch (_: Exception) {
            }
        }

        return parseFilament(uid, blocks)
    }

    private fun parseFilament(
        uid: ByteArray,
        blocks: Map<Int, ByteArray>
    ): Map<String, Any?> {
        fun block(index: Int): ByteArray =
            blocks[index] ?: throw IllegalStateException("MISSING_BLOCK_$index")

        val b1 = block(1)
        val b2 = block(2)
        val b4 = block(4)
        val b5 = block(5)
        val b6 = block(6)
        val b12 = block(12)
        val b16 = block(16)

        val variantId = ascii(b1, 0, 8)
        val materialId = ascii(b1, 8, 8)
        val filamentType = ascii(b2, 0, 16)
        val detailedType = ascii(b4, 0, 16)
        val productionDateRaw = ascii(b12, 0, 16)

        val colorHex = String.format(
            "#%02X%02X%02X",
            b5[0].toInt() and 0xFF,
            b5[1].toInt() and 0xFF,
            b5[2].toInt() and 0xFF,
        )

        val hasExtraColor = littleU16(b16, 0) == 2
        val colorCount = if (hasExtraColor) littleU16(b16, 2) else 1
        val secondaryColorHex = if (colorCount >= 2) {
            String.format(
                "#%02X%02X%02X",
                b16[7].toInt() and 0xFF,
                b16[6].toInt() and 0xFF,
                b16[5].toInt() and 0xFF,
            )
        } else null

        return linkedMapOf(
            "uid" to uid.toHex(),
            "filamentType" to filamentType,
            "detailedType" to detailedType,
            "materialId" to materialId,
            "variantId" to variantId,
            "colorHex" to colorHex,
            "secondaryColorHex" to secondaryColorHex,
            "spoolWeightG" to littleU16(b5, 4),
            "diameterMm" to littleFloat(b5, 8).toDouble(),
            "dryingTempC" to littleU16(b6, 0),
            "dryingTimeH" to littleU16(b6, 2),
            "productionDateRaw" to productionDateRaw,
            "bedTempC" to littleU16(b6, 6),
            "maxHotendC" to littleU16(b6, 8),
            "minHotendC" to littleU16(b6, 10),
        )
    }

    private fun deriveKeys(uid: ByteArray, context: String): List<ByteArray> {
        val salt = byteArrayOf(
            0x9A.toByte(), 0x75, 0x9C.toByte(), 0xF2.toByte(),
            0xC4.toByte(), 0xF7.toByte(), 0xCA.toByte(), 0xFF.toByte(),
            0x22, 0x2C, 0xB9.toByte(), 0x76,
            0x9B.toByte(), 0x41, 0xBC.toByte(), 0x96.toByte()
        )
        val info = context.toByteArray(StandardCharsets.ISO_8859_1)
        val okm = hkdfSha256(uid, salt, info, 16 * 6)
        return (0 until 16).map { index ->
            okm.copyOfRange(index * 6, index * 6 + 6)
        }
    }

    private fun hkdfSha256(
        ikm: ByteArray,
        salt: ByteArray,
        info: ByteArray,
        length: Int,
    ): ByteArray {
        val extractMac = Mac.getInstance("HmacSHA256")
        extractMac.init(SecretKeySpec(salt, "HmacSHA256"))
        val prk = extractMac.doFinal(ikm)

        val output = ByteArray(length)
        var previous = ByteArray(0)
        var offset = 0
        var counter = 1

        while (offset < length) {
            val expandMac = Mac.getInstance("HmacSHA256")
            expandMac.init(SecretKeySpec(prk, "HmacSHA256"))
            expandMac.update(previous)
            expandMac.update(info)
            expandMac.update(counter.toByte())
            previous = expandMac.doFinal()

            val toCopy = minOf(previous.size, length - offset)
            previous.copyInto(output, offset, 0, toCopy)
            offset += toCopy
            counter++
        }
        return output
    }

    private fun ascii(bytes: ByteArray, offset: Int, length: Int): String {
        val slice = bytes.copyOfRange(offset, offset + length)
        val end = slice.indexOfFirst { it.toInt() == 0 }.let { if (it == -1) slice.size else it }
        return String(slice, 0, end, StandardCharsets.US_ASCII).trim()
    }

    private fun littleU16(bytes: ByteArray, offset: Int): Int {
        return (bytes[offset].toInt() and 0xFF) or
            ((bytes[offset + 1].toInt() and 0xFF) shl 8)
    }

    private fun littleFloat(bytes: ByteArray, offset: Int): Float {
        return ByteBuffer.wrap(bytes, offset, 4)
            .order(ByteOrder.LITTLE_ENDIAN)
            .float
    }

    private fun ByteArray.toHex(): String =
        joinToString(separator = "") { "%02X".format(it.toInt() and 0xFF) }

    private fun emit(payload: Map<String, Any?>) {
        runOnUiThread {
            eventSink?.success(payload)
        }
    }

    private fun friendlyErrorCode(error: Exception): String {
        val message = error.message.orEmpty()
        return when {
            message.contains("MIFARE_CLASSIC_UNSUPPORTED") -> "mifareUnsupported"
            message.contains("UNEXPECTED_UID_LENGTH") -> "unexpectedUid"
            message.contains("AUTH_FAILED") -> "authFailed"
            message.contains("MISSING_BLOCK") -> "missingBlock"
            else -> "readFailed"
        }
    }

    private fun friendlyError(error: Exception): String {
        val message = error.message.orEmpty()
        return when {
            message.contains("MIFARE_CLASSIC_UNSUPPORTED") ->
                "此手机的 NFC 芯片不支持 MIFARE Classic"
            message.contains("UNEXPECTED_UID_LENGTH") ->
                "检测到的不是标准 Bambu Lab RFID 标签"
            message.contains("AUTH_FAILED") ->
                "RFID 认证失败，请重新贴近线盘"
            message.contains("MISSING_BLOCK") ->
                "RFID 数据不完整，请重新读取"
            else -> "无法读取此 RFID 标签"
        }
    }
}
