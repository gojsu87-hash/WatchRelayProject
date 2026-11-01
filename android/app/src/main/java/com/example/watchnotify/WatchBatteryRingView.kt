package com.example.watchnotify

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.util.AttributeSet
import android.util.TypedValue
import android.view.View
import androidx.core.content.ContextCompat
import kotlin.math.min

class WatchBatteryRingView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : View(context, attrs, defStyleAttr) {

    private val density = resources.displayMetrics.density
    private val textSize = TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_SP,
        12f,
        resources.displayMetrics
    )
    private var batteryLevel = -1

    private val trackPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeWidth = 3.5f * density
        color = ContextCompat.getColor(context, R.color.status_neutral)
    }

    private val progressPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeWidth = 3.5f * density
        color = ContextCompat.getColor(context, R.color.status_green)
    }

    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textAlign = Paint.Align.CENTER
        textSize = this@WatchBatteryRingView.textSize
        typeface = android.graphics.Typeface.create(
            "sans-serif-medium",
            android.graphics.Typeface.NORMAL
        )
        color = ContextCompat.getColor(context, R.color.primary_text)
    }

    fun setBatteryLevel(level: Int) {
        batteryLevel = level.takeIf { it in 0..100 } ?: -1
        contentDescription = if (batteryLevel >= 0) {
            "워치 배터리 $batteryLevel 퍼센트"
        } else {
            "워치 배터리 정보 대기 중"
        }
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)

        val centerX = width / 2f
        val centerY = height / 2f
        val radius = (min(width, height) - trackPaint.strokeWidth) / 2f
        val bounds = RectF(
            centerX - radius,
            centerY - radius,
            centerX + radius,
            centerY + radius
        )

        canvas.drawArc(bounds, -90f, 360f, false, trackPaint)
        if (batteryLevel >= 0) {
            canvas.drawArc(bounds, -90f, 360f * batteryLevel / 100f, false, progressPaint)
        }

        val label = if (batteryLevel >= 0) "$batteryLevel%" else "--"
        val baseline = centerY - (textPaint.ascent() + textPaint.descent()) / 2f
        canvas.drawText(label, centerX, baseline, textPaint)
    }
}
