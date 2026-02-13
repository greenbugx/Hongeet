package com.dxku.hongit.backend.youtube

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLException
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

class YoutubeExtractorBridge(
    context: Context
) {
    private val appContext = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())
    private val engine = YoutubeExtractorEngine()

    companion object {
        const val CHANNEL_NAME = "youtube_extractor"
        private const val TAG = "YoutubeExtractor"
    }

    fun initialize() {
        try {
            YoutubeDL.getInstance().init(appContext)
            maybeUpdateYtDlpInBackground()
        } catch (e: YoutubeDLException) {
            Log.e(TAG, "Failed to init yt-dlp", e)
        }
    }

    fun attach(binaryMessenger: BinaryMessenger) {
        MethodChannel(binaryMessenger, CHANNEL_NAME).setMethodCallHandler { call, result ->
            when (call.method) {
                "extractAudio" -> {
                    val videoId = call.argument<String>("videoId")?.trim().orEmpty()
                    val dataSaver = call.argument<Boolean>("dataSaver") ?: false
                    val authHeaders = call.argument<Map<String, Any?>>("authHeaders").toStringMap()
                    if (videoId.isBlank()) {
                        result.error("missing_video_id", "videoId is required", null)
                        return@setMethodCallHandler
                    }

                    runBg {
                        try {
                            val payload = engine.extractBestAudio(videoId, authHeaders, dataSaver)
                            mainHandler.post { result.success(payload) }
                        } catch (e: Exception) {
                            mainHandler.post {
                                result.error("extract_failed", engine.toClientExtractErrorMessage(e), null)
                            }
                        }
                    }
                }

                "extractAudioUrl" -> {
                    val videoId = call.argument<String>("videoId")?.trim().orEmpty()
                    val dataSaver = call.argument<Boolean>("dataSaver") ?: false
                    val authHeaders = call.argument<Map<String, Any?>>("authHeaders").toStringMap()
                    if (videoId.isBlank()) {
                        result.error("missing_video_id", "videoId is required", null)
                        return@setMethodCallHandler
                    }

                    runBg {
                        try {
                            val payload = engine.extractBestAudio(videoId, authHeaders, dataSaver)
                            val url = payload["url"] as? String
                                ?: throw IllegalStateException("No playable audio URL extracted")
                            mainHandler.post { result.success(url) }
                        } catch (e: Exception) {
                            mainHandler.post {
                                result.error("extract_failed", engine.toClientExtractErrorMessage(e), null)
                            }
                        }
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun runBg(block: () -> Unit) {
        Thread(block).start()
    }

    private fun maybeUpdateYtDlpInBackground() {
        Thread {
            try {
                val status = YoutubeDL.getInstance()
                    .updateYoutubeDL(appContext, YoutubeDL.UpdateChannel.STABLE)
                val version = YoutubeDL.getInstance().version(appContext)
                Log.i(TAG, "yt-dlp update status=$status version=$version")
            } catch (e: Exception) {
                Log.w(TAG, "yt-dlp update skipped: ${e.message}")
            }
        }.start()
    }

    private fun Map<String, Any?>?.toStringMap(): Map<String, String> {
        if (this == null) return emptyMap()
        val out = HashMap<String, String>()
        for ((key, value) in this) {
            val k = key.trim()
            val v = value?.toString()?.trim().orEmpty()
            if (k.isNotEmpty() && v.isNotEmpty()) {
                out[k] = v
            }
        }
        return out
    }
}

