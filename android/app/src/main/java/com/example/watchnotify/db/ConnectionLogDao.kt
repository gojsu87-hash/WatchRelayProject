package com.example.watchnotify.db

import androidx.room.*

@Dao
interface ConnectionLogDao {

    @Insert
    suspend fun insert(log: ConnectionLogEntity)

    @Query("SELECT * FROM connection_logs ORDER BY id DESC LIMIT 50")
    suspend fun getAll(): List<ConnectionLogEntity>

    @Query("DELETE FROM connection_logs WHERE id NOT IN (SELECT id FROM connection_logs ORDER BY id DESC LIMIT 50)")
    suspend fun trimOld()

    @Query("DELETE FROM connection_logs")
    suspend fun deleteAll()
}