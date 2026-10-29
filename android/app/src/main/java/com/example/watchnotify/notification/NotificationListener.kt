package com.example.watchnotify.notification

import android.app.Notification
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.telephony.TelephonyManager
import android.util.Log
import com.example.watchnotify.AppSettings
import com.example.watchnotify.ble.BleManager
import com.example.watchnotify.db.AppDatabase
import com.example.watchnotify.db.NotificationEntity
import com.example.watchnotify.telegram.TelegramManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

class NotificationListener : NotificationListenerService() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

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

    @Volatile private var isOutgoingCall = false
    @Volatile private var isRinging = false
    @Volatile private var isInCall = false

    private val phoneStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                TelephonyManager.ACTION_PHONE_STATE_CHANGED -> {
                    val state = intent.getStringExtra(TelephonyManager.EXTRA_STATE)
                    when (state) {
                        TelephonyManager.EXTRA_STATE_RINGING -> {
                            isOutgoingCall = false
                            isRinging = true
                            isInCall = false
                            Log.d(TAG, "수신 전화 감지")
                        }
                        TelephonyManager.EXTRA_STATE_OFFHOOK -> {
                            if (isRinging) {
                                isRinging = false
                                isInCall = true
                                isOutgoingCall = false
                                sendBleSignal("CALL_ANSWERED")
                                Log.d(TAG, "수신 전화 연결됨 → CALL_ANSWERED")
                            } else {
                                isOutgoingCall = true
                                isRinging = false
                                isInCall = false
                                Log.d(TAG, "발신 전화 감지 (워치 전송 제외)")
                            }
                        }
                        TelephonyManager.EXTRA_STATE_IDLE -> {
                            val wasInCall = isInCall
                            val wasRinging = isRinging
                            val wasOutgoing = isOutgoingCall

                            isOutgoingCall = false
                            isRinging = false
                            isInCall = false
                            callStartTime = 0

                            // 수신 전화였을 때만 통화종료/부재중 신호 전송
                            if (!wasOutgoing) {
                                when {
                                    wasInCall  -> sendBleSignal("CANCEL_CALL")
                                    wasRinging -> sendBleSignal("MISSED_CALL")
                                }
                            }
                            Log.d(TAG, "통화 종료 (wasOutgoing=$wasOutgoing)")
                        }
                    }
                }
            }
        }
    }

    private var callStartTime: Long = 0

    override fun onCreate() {
        super.onCreate()
        val filter = IntentFilter().apply {
            addAction(TelephonyManager.ACTION_PHONE_STATE_CHANGED)
        }
        registerReceiver(phoneStateReceiver, filter)
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
        unregisterReceiver(phoneStateReceiver)
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
            val isIncomingCall = (text.contains("수신 전화") || title.contains("수신 전화") || text.contains("전화 왔음")) && !isOutgoingCall && !isInCall
            val isOutgoingText = text.contains("발신") || title.contains("발신") || text.contains("통화 중") || title.contains("통화 중")

            if (isOutgoingText || isOutgoingCall) {
                Log.d(TAG, "익시오 발신 전화 알림 차단: $title / $text")
                return
            }

            if (isIncomingCall && callStartTime == 0L) {
                callStartTime = System.currentTimeMillis()
                scope.launch {
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

        scope.launch {
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

    private fun sendNotification(
        id: Long,
        packageName: String,
        title: String,
        text: String,
        subText: String = ""
    ) {
        if (id < 0) return
        when (AppSettings.getMode(applicationContext)) {
            AppSettings.MODE_BLE -> try {
                BleManager.getInstance(applicationContext)
                    .sendNotification(id, packageName, title, text)
            } catch (e: Exception) {
                Log.e(TAG, "BLE 전송 오류: ${e.message}")
            }
            AppSettings.MODE_API ->
                TelegramManager.getInstance(applicationContext)
                    .sendNotification(packageName, title, text, subText)
        }
    }

    private fun sendBleSignal(signal: String) {
        try {
            BleManager.getInstance(applicationContext).sendSignal(signal)
        } catch (e: Exception) {
            Log.e(TAG, "BLE 신호 오류: ${e.message}")
        }
    }

    private suspend fun saveToDatabase(packageName: String, title: String, text: String): Long {
        return try {
            val db = AppDatabase.getInstance(applicationContext)
            db.notificationDao().insert(
                NotificationEntity(event = "$packageName | $title", msg = text)
            )
        } catch (e: Exception) { -1L }
    }

    companion object {
        private const val TAG = "NotificationListener"

        private val outgoingFilterPackages = setOf(
            "com.kakao.talk",
            "com.microsoft.teams"
        )
    }
}