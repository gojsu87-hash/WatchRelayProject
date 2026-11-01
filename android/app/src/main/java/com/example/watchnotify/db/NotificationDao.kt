package com.example.watchnotify.db

import androidx.room.*

@Dao
interface NotificationDao {
    @Insert
    suspend fun insert(n: NotificationEntity): Long
    @Query("SELECT * FROM notifications WHERE status = 'PENDING' ORDER BY id ASC")
    suspend fun getPending(): List<NotificationEntity>
    @Query("SELECT * FROM notifications WHERE id > :lastId AND status = 'PENDING' ORDER BY id ASC")
    suspend fun getPendingAfter(lastId: Int): List<NotificationEntity>
    @Query("SELECT MAX(id) FROM notifications")
    suspend fun getLatestId(): Int?
    @Query("UPDATE notifications SET status = 'ACKED' WHERE id <= :id AND status = 'PENDING'")
    suspend fun markAckedThrough(id: Int)
    @Query("UPDATE notifications SET status = 'ACKED' WHERE id = :id")
    suspend fun markAcked(id: Int)
    @Query(
        "UPDATE notifications SET apiFallbackAttempted = 1 " +
            "WHERE id = :id AND status = 'PENDING' AND apiFallbackAttempted = 0"
    )
    suspend fun claimApiFallback(id: Int): Int
    @Query("UPDATE notifications SET apiFallbackAttempted = 0 WHERE id = :id AND status = 'PENDING'")
    suspend fun releaseApiFallback(id: Int)
    @Query("UPDATE notifications SET retryCount = retryCount + 1 WHERE id = :id")
    suspend fun incrementRetry(id: Int)
    @Query("DELETE FROM notifications WHERE status = 'ACKED'")
    suspend fun deleteAcked()
    @Query("SELECT id FROM notifications WHERE status = 'ACKED'")
    suspend fun getAckedIds(): List<Int>
}