package com.example.watchnotify.db

import androidx.room.Entity
import androidx.room.PrimaryKey

@Entity(tableName = "notifications")
data class NotificationEntity(
    @PrimaryKey(autoGenerate = true)
    val id: Int = 0,

    val event: String,
    val msg: String,

    val status: String = "PENDING",
    val retryCount: Int = 0,
    val createdAt: Long = System.currentTimeMillis()
)