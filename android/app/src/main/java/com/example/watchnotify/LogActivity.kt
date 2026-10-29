package com.example.watchnotify

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import com.example.watchnotify.db.AppDatabase
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class LogActivity : AppCompatActivity() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val handler = Handler(Looper.getMainLooper())
    private val updateRunnable = object : Runnable {
        override fun run() {
            loadLogs()
            handler.postDelayed(this, 3000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_log)
        val screenHeight = windowManager.currentWindowMetrics.bounds.height()
        window.setLayout(WindowManager.LayoutParams.MATCH_PARENT, (screenHeight * 0.9).toInt())
    }

    override fun onResume() {
        super.onResume()
        handler.post(updateRunnable)
    }

    override fun onPause() {
        super.onPause()
        handler.removeCallbacks(updateRunnable)
    }

    private fun loadLogs() {
        scope.launch {
            try {
                val db = AppDatabase.getInstance(applicationContext)
                val dbLogs = db.connectionLogDao().getAll()

                val text = if (dbLogs.isEmpty()) {
                    "로그 없음"
                } else {
                    dbLogs.joinToString("\n") { it.message }
                }

                withContext(Dispatchers.Main) {
                    findViewById<TextView>(R.id.tvLogs).text = text
                }
            } catch (e: Exception) {
                withContext(Dispatchers.Main) {
                    findViewById<TextView>(R.id.tvLogs).text = "로그 불러오기 실패: ${e.message}"
                }
            }
        }
    }
}