package com.example.watchnotify

import android.content.Context

object AppSettings {

    private const val PREF_NAME = "watchnotify_settings"
    private const val KEY_MODE = "notification_mode"

    const val MODE_BLE = "BLE"
    const val MODE_API = "API"

    fun getMode(context: Context): String {
        return context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .getString(KEY_MODE, MODE_BLE) ?: MODE_BLE
    }

    fun setMode(context: Context, mode: String) {
        context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_MODE, mode)
            .apply()
    }

    fun isBleMode(context: Context) = getMode(context) == MODE_BLE
    fun isApiMode(context: Context) = getMode(context) == MODE_API
}