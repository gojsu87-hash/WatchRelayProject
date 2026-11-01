package com.example.watchnotify.db

import android.content.Context
import androidx.room.Database
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.room.Room
import androidx.room.RoomDatabase

@Database(
    entities = [
        NotificationEntity::class,
        ConnectionLogEntity::class  // ← 추가
    ],
    version = 3,
    exportSchema = false
)
abstract class AppDatabase : RoomDatabase() {

    abstract fun notificationDao(): NotificationDao
    abstract fun connectionLogDao(): ConnectionLogDao  // ← 추가

    companion object {
        private val MIGRATION_2_3 = object : Migration(2, 3) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    "ALTER TABLE notifications ADD COLUMN apiFallbackAttempted INTEGER NOT NULL DEFAULT 0"
                )
            }
        }

        @Volatile
        private var INSTANCE: AppDatabase? = null

        fun getInstance(context: Context): AppDatabase {
            return INSTANCE ?: synchronized(this) {
                Room.databaseBuilder(
                    context.applicationContext,
                    AppDatabase::class.java,
                    "notifications.db"
                )
                    .addMigrations(MIGRATION_2_3)
                    .fallbackToDestructiveMigration()  // ← 추가 (버전 변경 시 자동 마이그레이션)
                    .build().also { INSTANCE = it }
            }
        }
    }
}