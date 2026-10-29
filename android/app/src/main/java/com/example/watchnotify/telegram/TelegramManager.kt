package com.example.watchnotify.telegram

import android.content.Context
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.util.concurrent.TimeUnit

class TelegramManager private constructor(private val context: Context) {

    companion object {
        private const val TAG = "TelegramManager"
        private const val CHAT_ID = "8797214914"

        // 카카오톡
        private const val TOKEN_KAKAO = "7969070691:AAHNQpXTe4jFVdvR-LylLu1NBAnqxV9Zce4"

        // 문자
        private const val TOKEN_SMS = "8666563344:AAErQahpHCs14DkKHJMqHjHGIztkhVYKAl8"

        // 전화
        private const val TOKEN_CALL = "8650906693:AAFIiHtVNyf8EhEB5b3PoahNruyGTtkbYBg"

        // 당근
        private const val TOKEN_DAANGN = "8651322181:AAHPXg7c8m9tMChbdr19l1jJ8ZPWNIcVlKM"

        // 코나카드, 코나아이
        private const val TOKEN_KONA = "8644955724:AAEA4UI_dUbdT7bATG2C1VV5YVfajLhkDy4"

        // 경기지역화폐
        private const val TOKEN_GYEONGGI = "8922090293:AAGr2MV7HVyuPLQGAmZo7-9YawbqjgPauig"

        // 하나은행, 하나카드
        private const val TOKEN_HANA = "8257621295:AAF0Fj_0snupe0fREw3cH4zs3Ic3umIztsI"

        // 국민은행, 국민카드
        private const val TOKEN_KB = "8691101984:AAHOGGvbNL-vsQ5BzFvXcZ5LUedgwWaEbXg"

        // 코나카드, 코나아이 아래에 추가
        private const val TOKEN_NAVER = "8735689439:AAEbe36tOxnoe3mJ9llV2XzP_laEoNifJ3w"

        // 와이뽀
        private const val TOKEN_WAIPPO = "8762436679:AAEwdnmS5HLe9GmjHRxfeO3IT7roD7kilvY"

        // 화도
        private const val TOKEN_HWADO = "8628839503:AAGTOCB-I3amTXQPox7-eVD4_E1Fmv-0ap4"

        // 우리가족
        private const val TOKEN_FAMILY = "8776578485:AAFRGiUETLgHANvwT_6qQ8YFY3FbA4_0hdo"

        // ✅ Teams
        private const val TOKEN_TEAMS = "8701697889:AAH4wy84M8suOiUc3MvxEg2FrE_ONzgq4YM"

        @Volatile
        private var instance: TelegramManager? = null

        fun getInstance(context: Context): TelegramManager {
            return instance ?: synchronized(this) {
                instance ?: TelegramManager(context.applicationContext).also {
                    instance = it
                }
            }
        }
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .build()

    // ✅ 마지막 전송된 메시지 ID 추적 (중복 방지)
    private var lastSentMessageKey = ""
    private val DUPLICATE_SEND_WINDOW_MS = 1000L

    // 패키지명 + 제목 → 토큰 매핑
    private fun getToken(
        packageName: String,
        title: String,
        subText: String = ""
    ): String {
        return when (packageName) {

            // 카카오톡 세분화
            "com.kakao.talk" -> when {
                // subText(채팅방명) 기준으로 먼저 확인
                subText.contains("와이뽀") -> TOKEN_WAIPPO
                subText.contains("화도") -> TOKEN_HWADO
                subText.contains("우리가족") -> TOKEN_FAMILY

                // subText 없으면 title(보낸사람) 기준으로 확인
                title.contains("와이뽀") -> TOKEN_WAIPPO
                title.contains("화도") -> TOKEN_HWADO
                title.contains("엄마") || title.contains("아빠") || title.contains("누나") ->
                    TOKEN_FAMILY

                else -> TOKEN_KAKAO
            }

            // 문자
            "com.samsung.android.messaging",
            "com.android.mms" -> TOKEN_SMS

            // 전화
            "com.lguplus.aicallagent",
            "com.uplus.ubizai" -> TOKEN_CALL

            // 당근
            "com.towneers.www" -> TOKEN_DAANGN

            // 네이버
            "com.nhn.android.search",
            "com.naverfin.payapp",
            "com.navercorp.ncp.sell" -> TOKEN_NAVER

            // 하나은행, 하나카드, 하나머니
            "com.hanabank.oqf",
            "com.kebhana.hanapush",
            "com.hanaskcard.paycla",
            "kr.co.hanamembers.hmscustomer" -> TOKEN_HANA

            // 코나카드, 코나아이
            "com.kona.card",
            "com.konai.konamoney" -> TOKEN_KONA

            // 경기지역화폐
            "kr.go.gg.ggcard",
            "gov.gyeonggi.ggcard" -> TOKEN_GYEONGGI

            // 국민은행, 국민카드
            "com.kbstar.kbbank",
            "com.kbcard.cxh.appcard" -> TOKEN_KB

            // ✅ Teams 추가
            "com.microsoft.teams" -> TOKEN_TEAMS

            // 기타
            else -> TOKEN_KAKAO
        }
    }

    fun sendNotification(
        packageName: String,
        title: String,
        body: String,
        subText: String = ""
    ) {
        // ✅ 중복 전송 방지
        val messageKey = "$packageName|$title|$body"
        val now = System.currentTimeMillis()
        if (lastSentMessageKey == messageKey) {
            Log.d(TAG, "중복 전송 무시: $title")
            return
        }
        lastSentMessageKey = messageKey

        scope.launch {
            try {
                val token = getToken(packageName, title, subText)

                // 보낸사람\n내용 형식으로 전송
                val text = "$title\n$body"

                val json = JSONObject().apply {
                    put("chat_id", CHAT_ID)
                    put("text", text)
                }

                val requestBody = json.toString()
                    .toRequestBody("application/json".toMediaType())

                val request = Request.Builder()
                    .url("https://api.telegram.org/bot$token/sendMessage")
                    .post(requestBody)
                    .build()

                val response = client.newCall(request).execute()

                if (response.isSuccessful) {
                    Log.d(TAG, "전송 성공: $title")
                } else {
                    Log.e(TAG, "전송 실패: ${response.code} - ${response.body?.string()}")
                }

            } catch (e: Exception) {
                Log.e(TAG, "전송 오류: ${e.message}")
            }
        }
    }
}
