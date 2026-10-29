package com.example.watchnotify // 아버님의 패키지명 확인

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.*
import android.widget.RemoteViews
import com.example.watchnotify.ble.BleManager

class WatchNotifyWidget : AppWidgetProvider() {

    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        for (appWidgetId in appWidgetIds) {
            updateWidget(context, appWidgetManager, appWidgetId)
        }
    }

    companion object {
        fun updateWidget(context: Context, appWidgetManager: AppWidgetManager, appWidgetId: Int) {
            val bleManager = BleManager.getInstance(context)
            val battery = bleManager.watchBatteryLevel

            val views = RemoteViews(context.packageName, R.layout.widget_main)
            val widgetBitmap = drawWidget(context, battery)
            views.setImageViewBitmap(R.id.ivWidgetCanvas, widgetBitmap)

            val intent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val pendingIntent = PendingIntent.getActivity(
                context, 0, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.rootLayout, pendingIntent)

            appWidgetManager.updateAppWidget(appWidgetId, views)
        }

        private fun drawWidget(context: Context, battery: Int): Bitmap {
            val size = 512
            val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)

            val cx = size / 2f
            val cy = size * 0.38f // 아크와 시계 뭉치를 전체적으로 약간 위로
            val radius = size * 0.29f // 배경과의 여백을 위해 조금 더 축소 (0.30f -> 0.29f)

            // 1. [수정] 배경 모양: 아주 동글동글한 느낌으로 (곡률 대폭 상향)
            val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = Color.parseColor("#121212")
                style = Paint.Style.FILL
            }
            // 140f 이상 주어 모서리가 아주 완만하게 돌아가도록 수정
            canvas.drawRoundRect(RectF(0f, 0f, size.toFloat(), size.toFloat()), 145f, 145f, bgPaint)

            // 2. 아크 게이지 (슬림하고 묵직한 선 유지)
            val strokeWidth = size * 0.105f
            val arcRect = RectF(cx - radius, cy - radius, cx + radius, cy + radius)

            val trackPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = Color.parseColor("#252525")
                style = Paint.Style.STROKE
                this.strokeWidth = strokeWidth
                strokeCap = Paint.Cap.ROUND
            }
            canvas.drawArc(arcRect, 140f, 260f, false, trackPaint)

            if (battery >= 0) {
                val progressPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    color = Color.parseColor("#3DDC84")
                    style = Paint.Style.STROKE
                    this.strokeWidth = strokeWidth
                    strokeCap = Paint.Cap.ROUND
                }
                canvas.drawArc(arcRect, 140f, 260f * (battery / 100f), false, progressPaint)
            }

            // 3. 중앙 애플워치 울트라 아이콘
            val iconPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = Color.WHITE
                style = Paint.Style.STROKE
                this.strokeWidth = size * 0.035f
                strokeCap = Paint.Cap.ROUND
            }

            val w = size * 0.075f
            val h = size * 0.095f
            canvas.drawRoundRect(RectF(cx - w, cy - h, cx + w, cy + h), 10f, 10f, iconPaint)

            // 용두 가드 파트
            val crownX = cx + w
            val guardRect = RectF(crownX, cy - (h * 0.2f), crownX + (w * 0.18f), cy + (h * 0.25f))
            canvas.drawRoundRect(guardRect, 5f, 5f, iconPaint)

            // 스트랩
            val sO = size * 0.042f
            val sL = size * 0.025f
            canvas.drawLine(cx - sO, cy - h, cx - sO, cy - h - sL, iconPaint)
            canvas.drawLine(cx + sO, cy - h, cx + sO, cy - h - sL, iconPaint)
            canvas.drawLine(cx - sO, cy + h, cx - sO, cy + h + sL, iconPaint)
            canvas.drawLine(cx + sO, cy + h, cx + sO, cy + h + sL, iconPaint)

            // 4. [수정] 폰트 정밀 튜닝 (높이 축소 및 장평 압축)
            val batteryText = if (battery in 0..100) "$battery" else "--"
            val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = Color.WHITE
                textSize = size * 0.19f // 높이를 더 낮춤 (0.20f -> 0.19f)
                typeface = Typeface.create("sans-serif-condensed", Typeface.BOLD)
                textAlign = Paint.Align.CENTER
                textScaleX = 0.82f // 옆으로 더 좁게 (0.85f -> 0.82f)
                letterSpacing = -0.08f // 자간을 더 밀착
            }
            // 숫자 위치를 아크 하단부 안쪽으로 더 정교하게 배치
            canvas.drawText(batteryText, cx, cy + radius + (size * 0.15f), textPaint)

            return bitmap
        }

        fun updateAllWidgets(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, WatchNotifyWidget::class.java))
            for (id in ids) {
                updateWidget(context, manager, id)
            }
        }
    }
}