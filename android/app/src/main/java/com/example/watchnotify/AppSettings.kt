package com.example.watchnotify

import android.content.Context

object AppSettings {

    private const val PREF_NAME = "watchnotify_settings"
    private const val KEY_MODE = "notification_mode"
    private const val KEY_SERVICE_ENABLED = "service_enabled"

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

    fun isServiceEnabled(context: Context): Boolean {
        return context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .getBoolean(KEY_SERVICE_ENABLED, true)
    }

    fun setServiceEnabled(context: Context, enabled: Boolean) {
        context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_SERVICE_ENABLED, enabled)
            .apply()
    }

    fun isBleMode(context: Context) = getMode(context) == MODE_BLE
    fun isApiMode(context: Context) = getMode(context) == MODE_API
}