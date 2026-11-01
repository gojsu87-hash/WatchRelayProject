package com.example.watchnotify.notification

import android.app.Notification
import android.content.ComponentName
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import com.example.watchnotify.AppSettings
import com.example.watchnotify.ble.BleManager
import com.example.watchnotify.ble.BleService
import com.example.watchnotify.db.AppDatabase
import com.example.watchnotify.db.NotificationEntity
import com.example.watchnotify.telegram.TelegramManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

class NotificationListener : NotificationListenerService() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    private val notificationDispatcher = Dispatchers.IO.limitedParallelism(1)

    // 최근 수신 메시지 추적 (중복 방지)
    private data class RecentMessage(val key: String, val timestamp: Long)
    private var lastMessage: RecentMessage? = null
    private val DUPLICATE_WINDOW_MS = 1000L  // 1초 내 중복 무시

    private val allowedPackages = setOf(
        "com.kakao.talk",
        "com.lguplus.aicallagent",
        "com.uplus.ubizai", // 익시오 패키지
        "com.samsung.android.messaging",
        "com.android.mms",
        "com.hanabank.oqf",
        "com.kebhana.hanapush",
        "com.hanaskcard.paycla",
        "kr.co.hanamembers.hmscustomer",
        "com.shinhan.sbanking",
        "com.shinhan.smartcaremgr",
        "com.shinhancard.smart",
        "com.kakaobank.channel",
        "com.kona.card",
        "com.konai.konamoney",
        "kr.go.gg.ggcard",
        "com.towneers.www",
        "com.nhn.android.search",
        "com.naverfin.payapp",
        "com.navercorp.ncp.sell",
        "com.kbstar.kbbank",
        "com.kbcard.cxh.appcard",
        "gov.gyeonggi.ggcard",
        "com.microsoft.teams"
    )

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "알림 리스너 시작됨")
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        Log.d(TAG, "알림 리스너 연결됨")
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        Log.d(TAG, "알림 리스너 끊김 → 재연결 시도")
        requestRebind(ComponentName(this, NotificationListener::class.java))
    }

    override fun onDestroy() {
        super.onDestroy()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        sbn ?: return
        val packageName = sbn.packageName

        if (packageName !in allowedPackages) return

        val isGroupSummary = sbn.notification.flags and Notification.FLAG_GROUP_SUMMARY != 0
        val extras = sbn.notification.extras
        val title = (extras.getCharSequence(Notification.EXTRA_TITLE)
            ?: extras.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)
            ?: extras.getCharSequence(Notification.EXTRA_TITLE_BIG)
            ?: extras.getCharSequence(Notification.EXTRA_SUB_TEXT)
            ?: "").toString().trim().ifBlank {
                if (packageName == "com.kakao.talk") "카카오톡" else ""
            }

        val rawText = (extras.getCharSequence(Notification.EXTRA_TEXT)
            ?: extras.getCharSequence(Notification.EXTRA_BIG_TEXT)
            ?: "").toString().trim()
        val text = if (rawText.isBlank()) "[이모티콘]" else rawText
        val subText = extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString() ?: ""

        val messageKey = "$packageName|$title|$text"
        val now = System.currentTimeMillis()
        if (lastMessage?.key == messageKey && (now - lastMessage!!.timestamp) < DUPLICATE_WINDOW_MS) {
            Log.d(TAG, "중복 알림 무시 (1초 내): $packageName | $title")
            return
        }
        lastMessage = RecentMessage(messageKey, now)

        if (isGroupSummary && rawText.isBlank()) return
        if (title.isBlank() && packageName != "com.hanabank.oqf") return

        if (isOutgoingMessage(packageName, title, text, extras)) {
            Log.d(TAG, "발신 메시지 알림 무시: $packageName | $title | $text")
            BleManager.getInstance(applicationContext).saveLog("⏭️ 발신 메시지 차단: $title - $text")
            return
        }

        if (packageName == "com.towneers.www" &&
            (title.contains("걸음") || title.contains("만보") ||
                    title.contains("동네걷기") || text.contains("동네걷기") ||
                    text.contains("걸음") || text.contains("만보"))) {
            Log.d(TAG, "당근 만보기 무시: $title")
            return
        }

        if (packageName == "com.hanabank.oqf" && isGroupSummary) return

        // 📞 유플러스 익시오 수신 전화만 허용 (발신/통화중 차단)
        if (packageName == "com.lguplus.aicallagent" || packageName == "com.uplus.ubizai") {
            val isIncomingCall =
                (text.contains("수신 전화") || title.contains("수신 전화") || text.contains("전화 왔음")) &&
                    BleService.isRinging && !BleService.isOutgoingCall && !BleService.isInCall
            val isOutgoingText = text.contains("발신") || title.contains("발신") || text.contains("통화 중") || title.contains("통화 중")

            if (isOutgoingText || BleService.isOutgoingCall) {
                Log.d(TAG, "익시오 발신 전화 알림 차단: $title / $text")
                return
            }

            if (isIncomingCall && !BleService.callNotificationSent) {
                BleService.callNotificationSent = true
                scope.launch(notificationDispatcher) {
                    val id = saveToDatabase(packageName, title, text)
                    sendNotification(id, packageName, title, text, subText)
                }
            } else {
                Log.d(TAG, "익시오 전화 알림 무시 (통화중 또는 중복): $title / $text")
            }
            return
        }

        Log.d(TAG, "알림 감지! 앱: $packageName | 제목: $title | 내용: $text")
        BleManager.getInstance(applicationContext).saveLog("📩 알림 감지: [$packageName] $title - $text")

        scope.launch(notificationDispatcher) {
            val id = saveToDatabase(packageName, title, text)
            sendNotification(id, packageName, title, text, subText)
        }
    }

    private fun isOutgoingMessage(
        packageName: String,
        title: String,
        text: String,
        extras: Bundle
    ): Boolean {
        if (packageName !in outgoingFilterPackages) return false

        val sender = getLatestMessageSender(extras)
        val selfDisplayName = extras.getCharSequence(Notification.EXTRA_SELF_DISPLAY_NAME)
            ?.toString()
            ?.trim()
            .orEmpty()

        if (sender.isNotBlank() && selfDisplayName.isNotBlank() && sender == selfDisplayName) {
            return true
        }

        val trimmedText = text.trim()
        val ownTextPrefixes = listOf("나:", "나 :", "You:", "You :", "Me:", "Me :")

        return when (packageName) {
            "com.kakao.talk" ->
                trimmedText.startsWithAny(ownTextPrefixes)

            "com.microsoft.teams" ->
                trimmedText.startsWithAny(listOf("You:", "You :", "Me:", "Me :"))

            else -> false
        }
    }

    private fun getLatestMessageSender(extras: Bundle): String {
        val messages = extras.getParcelableArray(Notification.EXTRA_MESSAGES) ?: return ""
        return messages
            .mapNotNull { it as? Bundle }
            .lastOrNull()
            ?.let { message ->
                message.getCharSequence("sender")?.toString()
                    ?: message.getBundle("sender_person")?.getCharSequence("name")?.toString()
            }
            ?.trim()
            .orEmpty()
    }

    private fun String.startsWithAny(prefixes: List<String>): Boolean {
        return prefixes.any { startsWith(it, ignoreCase = true) }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
    }

    private suspend fun sendNotification(
        id: Long,
        packageName: String,
        title: String,
        text: String,
        subText: String = ""
    ) {
        if (id < 0) {
            Log.e(TAG, "알림 DB 저장 실패; 실시간 전달을 계속합니다: $packageName | $title")
        }
        when (AppSettings.getMode(applicationContext)) {
            AppSettings.MODE_BLE -> {
                val bleManager = BleManager.getInstance(applicationContext)
                if (id <= 0L) {
                    Log.e(TAG, "알림을 저장하지 못해 BLE ACK를 추적할 수 없습니다; API로 전달합니다")
                    scope.launch { sendViaApi(packageName, title, text, subText) }
                } else if (!bleManager.isWatchResponsive) {
                    Log.w(TAG, "워치 응답 불가; 즉시 API 우회: $title")
                    scope.launch { sendApiFallback(id, packageName, title, text, subText) }
                } else {
                    try {
                        bleManager.sendNotification(id, packageName, title, text)
                        scope.launch {
                            delay(API_FALLBACK_ACK_TIMEOUT_MS)
                            sendApiFallback(id, packageName, title, text, subText)
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "BLE 전송 오류; API 우회: $title", e)
                        scope.launch { sendApiFallback(id, packageName, title, text, subText) }
                    }
                }
            }
            AppSettings.MODE_API -> scope.launch {
                if (sendViaApi(packageName, title, text, subText)) {
                    markApiDelivered(id)
                }
            }
        }
    }

    private suspend fun sendApiFallback(
        id: Long,
        packageName: String,
        title: String,
        text: String,
        subText: String
    ) {
        val dao = try {
            AppDatabase.getInstance(applicationContext).notificationDao()
        } catch (e: Exception) {
            Log.e(TAG, "API 우회 상태 조회 실패; 중복 방지 없이 전달 시도", e)
            sendViaApi(packageName, title, text, subText)
            return
        }
        val boundedId = id.coerceIn(1L, Int.MAX_VALUE.toLong()).toInt()
        repeat(API_FALLBACK_ATTEMPTS) { attempt ->
            val claimed = try {
                dao.claimApiFallback(boundedId)
            } catch (e: Exception) {
                Log.e(TAG, "API 우회 상태 기록 실패; 전달을 시도합니다 (id=$id)", e)
                sendViaApi(packageName, title, text, subText)
                return
            }
            if (claimed == 0) {
                Log.d(TAG, "API 우회 불필요: 이미 ACK되었거나 우회 처리됨 (id=$id)")
                return
            }
            if (sendViaApi(packageName, title, text, subText)) {
                markApiDelivered(id)
                return
            }

            try {
                dao.releaseApiFallback(boundedId)
            } catch (e: Exception) {
                Log.e(TAG, "API 우회 재시도 상태 초기화 실패 (id=$id)", e)
            }
            if (attempt < API_FALLBACK_ATTEMPTS - 1) delay(API_FALLBACK_RETRY_DELAY_MS)
        }
        Log.e(TAG, "API 우회 전송 실패: $title (id=$id)")
    }

    private suspend fun markApiDelivered(id: Long) {
        if (id <= 0L) return
        try {
            AppDatabase.getInstance(applicationContext)
                .notificationDao()
                .markAcked(id.coerceAtMost(Int.MAX_VALUE.toLong()).toInt())
        } catch (e: Exception) {
            Log.e(TAG, "API 전달 완료 상태 저장 실패 (id=$id)", e)
        }
    }

    private suspend fun sendViaApi(
        packageName: String,
        title: String,
        text: String,
        subText: String
    ): Boolean {
        val accepted = TelegramManager.getInstance(applicationContext)
            .sendNotificationAndAwait(packageName, title, text, subText)
        if (!accepted) {
            Log.e(TAG, "API 전달이 확인되지 않았습니다: $title")
            BleManager.getInstance(applicationContext)
                .recordFailureLog("Telegram API 알림 전송 실패: ${packageName}")
        }
        return accepted
    }

    private suspend fun saveToDatabase(packageName: String, title: String, text: String): Long {
        return try {
            val db = AppDatabase.getInstance(applicationContext)
            db.notificationDao().insert(
                NotificationEntity(event = "$packageName | $title", msg = text)
            )
        } catch (e: Exception) {
            Log.e(TAG, "알림 DB 저장 실패: $packageName | $title", e)
            BleManager.getInstance(applicationContext)
                .recordFailureLog("알림 DB 저장 실패: ${e.javaClass.simpleName}")
            -1L
        }
    }

    companion object {
        private const val TAG = "NotificationListener"
        private const val API_FALLBACK_ACK_TIMEOUT_MS = 8_000L
        private const val API_FALLBACK_RETRY_DELAY_MS = 2_000L
        private const val API_FALLBACK_ATTEMPTS = 2

        private val outgoingFilterPackages = setOf(
            "com.kakao.talk",
            "com.microsoft.teams"
        )
    }
}