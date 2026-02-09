package com.dxku.hongit.backend

import android.app.*
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Environment
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.*
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.FileOutputStream

class DownloadService : Service() {

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val client = OkHttpClient()

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()

        startForeground(
            FOREGROUND_ID,
            buildNotification("Preparing download", 0, false)
        )

    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val url = intent?.getStringExtra("url") ?: return START_NOT_STICKY
        val title = intent.getStringExtra("title") ?: "Downloading"

        scope.launch {
            startDownload(title, url)
        }

        return START_STICKY
    }

    private suspend fun startDownload(title: String, url: String) {
        try {
            // Create download directory
            val downloadDir = File(
                Environment.getExternalStoragePublicDirectory(
                    Environment.DIRECTORY_DOWNLOADS
                ),
                "Hongit"
            )

            if (!downloadDir.exists()) {
                downloadDir.mkdirs()
            }

            // Sanitize filename
            val safeTitle = title.replace(
                Regex("[\\\\/:*?\"<>|]"),
                "_"
            )

            // Direct download from URL (these are .mp4 files with AAC audio)
            updateNotification("Starting: $safeTitle", 0, false)

            val request = Request.Builder()
                .url(url)
                .build()

            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) {
                    throw Exception("Download failed: ${response.code}")
                }

                val totalBytes = response.body?.contentLength() ?: -1L
                val inputStream = response.body?.byteStream()
                    ?: throw Exception("No response body")

                // Save as .m4a (since it's AAC audio in mp4 container)
                val outputFile = File(downloadDir, "$safeTitle.m4a")
                val outputStream = FileOutputStream(outputFile)

                val buffer = ByteArray(8192)
                var bytesRead: Int
                var totalRead = 0L

                while (inputStream.read(buffer).also { bytesRead = it } != -1) {
                    outputStream.write(buffer, 0, bytesRead)
                    totalRead += bytesRead

                    // Update progress
                    if (totalBytes > 0) {
                        val progress = ((totalRead * 100) / totalBytes).toInt()
                        updateNotification(safeTitle, progress, false)
                    }
                }

                outputStream.flush()
                outputStream.close()
                inputStream.close()

                updateNotification("Completed: $safeTitle", 100, true)
                showCompletedNotification("Completed: $safeTitle")
                Log.i("DownloadService", "Download completed: ${outputFile.absolutePath}")
            }

        } catch (e: Exception) {
            Log.e("DownloadService", "Download failed", e)
            updateNotification("Failed: $title", 0, true)
            showCompletedNotification("Failed: $title")
        } finally {
            // final notification in the shade.
            delay(3000)
            try {
                stopForeground(true)
            } catch (_: Exception) {
                // Ignore;
            }
            stopSelf()
        }
    }


    private fun buildNotification(
        text: String,
        progress: Int,
        done: Boolean
    ): Notification {
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Hongit Download")
            .setContentText(text)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)

        if (done) {
            builder
                .setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setOngoing(false)
                .setProgress(0, 0, false)
        } else {
            builder
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setOngoing(true)
                .setProgress(100, progress, false)
        }

        return builder.build()
    }

    private fun updateNotification(
        text: String,
        progress: Int,
        done: Boolean
    ) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(FOREGROUND_ID, buildNotification(text, progress, done))

    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Downloads",
                NotificationManager.IMPORTANCE_LOW
            )
            getSystemService(NotificationManager::class.java)
                .createNotificationChannel(channel)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    private fun showCompletedNotification(text: String) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Hongit Download")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setOngoing(false)
            .setAutoCancel(true)
            .setShowWhen(true)
            .build()

        nm.notify(COMPLETED_NOTIFICATION_ID, notification)
    }

    companion object {
        private const val CHANNEL_ID = "hongit_downloads"
        private const val FOREGROUND_ID = 1001
        private const val COMPLETED_NOTIFICATION_ID = 1002

        fun start(context: Context, title: String, url: String) {
            val intent = Intent(context, DownloadService::class.java).apply {
                putExtra("title", title)
                putExtra("url", url)
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
    }
}