package com.dxku.hongit

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import com.dxku.hongit.backend.MainService
import com.ryanheise.audioservice.AudioServiceActivity
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLException
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {

    private val CHANNEL = "battery_optimization"
    private val YT_CHANNEL = "youtube_extractor"
    private val mainHandler = Handler(Looper.getMainLooper())

    companion object {
        private const val TAG = "YoutubeExtractor"
        private const val DEFAULT_USER_AGENT =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    }

    private data class ExtractAttempt(
        val label: String,
        val formatSelector: String,
        val extractorArgs: String?,
        val useAuthHeaders: Boolean
    )

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).setMethodCallHandler { call, result ->

            when (call.method) {
                "manufacturer" -> {
                    result.success(Build.MANUFACTURER)
                }

                "isIgnoring" -> {
                    val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                    result.success(pm.isIgnoringBatteryOptimizations(packageName))
                }

                "request" -> {
                    result.success(openBatteryOptimizationSettings())
                }

                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            YT_CHANNEL
        ).setMethodCallHandler { call, result ->

            fun runBg(block: () -> Unit) {
                Thread(block).start()
            }

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
                            val payload = extractBestAudio(videoId, authHeaders, dataSaver)
                            mainHandler.post { result.success(payload) }
                        } catch (e: Exception) {
                            mainHandler.post {
                                result.error("extract_failed", toClientExtractErrorMessage(e), null)
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
                            val payload = extractBestAudio(videoId, authHeaders, dataSaver)
                            val url = payload["url"] as? String
                                ?: throw IllegalStateException("No playable audio URL extracted")
                            mainHandler.post { result.success(url) }
                        } catch (e: Exception) {
                            mainHandler.post {
                                result.error("extract_failed", toClientExtractErrorMessage(e), null)
                            }
                        }
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            YoutubeDL.getInstance().init(this)
        } catch (e: YoutubeDLException) {
            Log.e(TAG, "Failed to init yt-dlp", e)
        }
        MainService.start(this)
    }

    private fun maybeUpdateYtDlpInBackground() {
        Thread {
            try {
                val status = YoutubeDL.getInstance()
                    .updateYoutubeDL(this, YoutubeDL.UpdateChannel.STABLE)
                val version = YoutubeDL.getInstance().version(this)
                Log.i(TAG, "yt-dlp update status=$status version=$version")
            } catch (e: Exception) {
                Log.w(TAG, "yt-dlp update skipped: ${e.message}")
            }
        }.start()
    }

    private fun extractBestAudio(
        videoId: String,
        authHeaders: Map<String, String>,
        dataSaver: Boolean
    ): Map<String, Any?> {
        val hasAuthHeaders = authHeaders.isNotEmpty()
        val preferredFormat = if (dataSaver) {
            "bestaudio[abr<=128][ext=m4a]/bestaudio[abr<=128][ext=webm]/" +
                "bestaudio[abr<=128]/bestaudio[ext=m4a]/bestaudio[ext=webm]/bestaudio/best"
        } else {
            "bestaudio[ext=m4a]/bestaudio[ext=webm]/bestaudio/best"
        }
        val attempts = listOf(
            ExtractAttempt(
                label = "android-fast",
                formatSelector = preferredFormat,
                extractorArgs = "youtube:player_client=android;player_skip=webpage,configs",
                useAuthHeaders = false
            ),
            ExtractAttempt(
                label = "android-web-auth",
                formatSelector = preferredFormat,
                extractorArgs = "youtube:player_client=android,web",
                useAuthHeaders = true
            ),
            ExtractAttempt(
                label = "compat-auth",
                formatSelector = if (dataSaver) "bestaudio[abr<=128]/bestaudio/best" else "bestaudio/best",
                extractorArgs = null,
                useAuthHeaders = true
            )
        ).filter { !it.useAuthHeaders || hasAuthHeaders }

        var lastError: Exception? = null

        for ((index, attempt) in attempts.withIndex()) {
            try {
                val payload = extractBestAudioWithAttempt(videoId, authHeaders, attempt)
                if (index > 0) {
                    Log.i(TAG, "Extraction succeeded via fallback path: ${attempt.label}")
                }
                return payload
            } catch (e: Exception) {
                lastError = e
                val hasNext = index < attempts.lastIndex
                val retryable = isRetryableExtractError(e)
                if (!hasNext || !retryable) {
                    break
                }
                Log.d(TAG, "Extraction fallback after '${attempt.label}': ${e.message}")
                Thread.sleep(((index + 1) * 120L).coerceAtMost(300L))
            }
        }

        throw IllegalStateException(
            toClientExtractErrorMessage(lastError ?: IllegalStateException("No playable audio URL extracted"))
        )
    }

    private fun extractBestAudioWithAttempt(
        videoId: String,
        authHeaders: Map<String, String>,
        attempt: ExtractAttempt
    ): Map<String, Any?> {
        val watchUrl = "https://www.youtube.com/watch?v=$videoId"
        val request = YoutubeDLRequest(watchUrl)

        request.addOption("--no-playlist")
        request.addOption("--no-warnings")
        request.addOption("--geo-bypass")
        request.addOption("--socket-timeout", "7")
        request.addOption("--retries", "0")
        request.addOption("--extractor-retries", "0")
        request.addOption("-f", attempt.formatSelector)

        if (!attempt.extractorArgs.isNullOrBlank()) {
            request.addOption("--extractor-args", attempt.extractorArgs)
        }

        if (attempt.useAuthHeaders) {
            applyAuthHeaders(request, authHeaders)
        }

        val info = YoutubeDL.getInstance().getInfo(request)
        val url = info.url?.trim().orEmpty()

        if (url.isBlank()) {
            throw IllegalStateException("No playable audio URL extracted")
        }

        val safeUrl = if (url.startsWith("http://")) {
            url.replaceFirst("http://", "https://")
        } else {
            url
        }

        val headers = HashMap<String, String>()
        info.httpHeaders?.let { headers.putAll(it) }

        if (!headers.containsKey("User-Agent")) {
            headers["User-Agent"] = DEFAULT_USER_AGENT
        }
        if (!headers.containsKey("Accept")) {
            headers["Accept"] = "*/*"
        }
        if (!headers.containsKey("Accept-Language")) {
            headers["Accept-Language"] = "en-US,en;q=0.9"
        }
        if (!headers.containsKey("Referer")) {
            headers["Referer"] = "https://www.youtube.com/"
        }
        if (!headers.containsKey("Origin")) {
            headers["Origin"] = "https://www.youtube.com"
        }

        return mapOf(
            "url" to safeUrl,
            "headers" to headers
        )
    }

    private fun isRetryableExtractError(e: Exception): Boolean {
        val msg = e.message?.lowercase().orEmpty()
        if (msg.isBlank()) return true

        val nonRetryableTokens = listOf(
            "private video",
            "members-only",
            "age-restricted",
            "confirm your age",
            "video unavailable",
            "this video is unavailable",
            "unavailable in your country",
            "geo restricted",
            "geo-restricted",
            "sign in to confirm your age"
        )
        return nonRetryableTokens.none { msg.contains(it) }
    }

    private fun toClientExtractErrorMessage(e: Exception): String {
        val msg = e.message?.trim().orEmpty()
        val lower = msg.lowercase()

        return when {
            lower.contains("age-restricted") || lower.contains("confirm your age") ->
                "Age-restricted content. Sign-in headers are required."
            lower.contains("private video") || lower.contains("members-only") ->
                "Private or members-only content cannot be streamed."
            lower.contains("unavailable in your country") ||
                lower.contains("geo restricted") ||
                lower.contains("geo-restricted") ->
                "Geo-restricted content is unavailable in this region."
            lower.contains("video unavailable") || lower.contains("this video is unavailable") ->
                "Video is unavailable."
            lower.contains("forbidden") || lower.contains("http error 403") ->
                "Access denied by source (403). Try refreshing auth headers."
            msg.isNotEmpty() -> msg
            else -> "No playable audio URL extracted."
        }
    }

    private fun applyAuthHeaders(
        request: YoutubeDLRequest,
        rawHeaders: Map<String, String>
    ) {
        val headers = normalizeAuthHeaders(rawHeaders)

        for ((key, value) in headers) {
            if (key.isBlank() || value.isBlank()) continue
            request.addOption("--add-header", "$key: $value")
        }

        if (!headers.containsKey("Referer")) {
            request.addOption("--add-header", "Referer: https://www.youtube.com/")
        }
        if (!headers.containsKey("Origin")) {
            request.addOption("--add-header", "Origin: https://www.youtube.com")
        }
    }

    private fun normalizeAuthHeaders(rawHeaders: Map<String, String>): Map<String, String> {
        if (rawHeaders.isEmpty()) return emptyMap()

        val normalized = HashMap<String, String>()
        val lower = HashMap<String, String>()

        for ((key, value) in rawHeaders) {
            val k = key.trim().lowercase()
            val v = value.trim()
            if (k.isEmpty() || v.isEmpty()) continue
            lower[k] = v
        }

        lower["cookie"]?.let { normalized["Cookie"] = it }
        lower["user-agent"]?.let { normalized["User-Agent"] = it }
        lower["accept"]?.let { normalized["Accept"] = it }
        lower["accept-language"]?.let { normalized["Accept-Language"] = it }
        lower["x-goog-visitor-id"]?.let { normalized["X-Goog-Visitor-Id"] = it }
        lower["x-goog-authuser"]?.let { normalized["X-Goog-AuthUser"] = it }
        lower["x-youtube-client-name"]?.let { normalized["X-Youtube-Client-Name"] = it }
        lower["x-youtube-client-version"]?.let { normalized["X-Youtube-Client-Version"] = it }
        lower["x-youtube-bootstrap-logged-in"]?.let { normalized["X-Youtube-Bootstrap-Logged-In"] = it }
        lower["x-origin"]?.let { normalized["X-Origin"] = it }
        lower["referer"]?.let { normalized["Referer"] = it }
        lower["origin"]?.let { normalized["Origin"] = it }

        return normalized
    }

    private fun openBatteryOptimizationSettings(): Boolean {
        val packageUri = Uri.parse("package:$packageName")
        val manufacturer = Build.MANUFACTURER.lowercase()

        val intents = mutableListOf<Intent>()

        intents += Intent(
            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            packageUri
        )
        intents += Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)

        if (
            manufacturer.contains("xiaomi") ||
            manufacturer.contains("redmi") ||
            manufacturer.contains("poco")
        ) {
            intents += Intent().apply {
                component = android.content.ComponentName(
                    "com.miui.powerkeeper",
                    "com.miui.powerkeeper.ui.HiddenAppsConfigActivity"
                )
                putExtra("package_name", packageName)
                putExtra("package_label", applicationInfo.loadLabel(packageManager).toString())
            }
            intents += Intent().apply {
                component = android.content.ComponentName(
                    "com.miui.securitycenter",
                    "com.miui.permcenter.autostart.AutoStartManagementActivity"
                )
            }
        }

        if (
            manufacturer.contains("oppo") ||
            manufacturer.contains("realme") ||
            manufacturer.contains("oneplus")
        ) {
            intents += Intent().apply {
                component = android.content.ComponentName(
                    "com.coloros.oppoguardelf",
                    "com.coloros.powermanager.fuelgaue.PowerUsageModelActivity"
                )
            }
            intents += Intent().apply {
                component = android.content.ComponentName(
                    "com.oplus.battery",
                    "com.oplus.powermanager.fuelgaue.PowerUsageModelActivity"
                )
            }
            intents += Intent().apply {
                component = android.content.ComponentName(
                    "com.coloros.safecenter",
                    "com.coloros.privacypermissionsentry.PermissionTopActivity"
                )
            }
        }

        if (manufacturer.contains("vivo")) {
            intents += Intent().apply {
                component = android.content.ComponentName(
                    "com.vivo.abe",
                    "com.vivo.applicationbehaviorengine.ui.ExcessivePowerManagerActivity"
                )
            }
        }

        if (manufacturer.contains("huawei") || manufacturer.contains("honor")) {
            intents += Intent().apply {
                component = android.content.ComponentName(
                    "com.huawei.systemmanager",
                    "com.huawei.systemmanager.optimize.process.ProtectActivity"
                )
            }
            intents += Intent().apply {
                component = android.content.ComponentName(
                    "com.huawei.systemmanager",
                    "com.huawei.systemmanager.appcontrol.activity.StartupAppControlActivity"
                )
            }
        }

        intents += Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, packageUri)

        for (intent in intents) {
            if (tryLaunchSettingsIntent(intent)) {
                return true
            }
        }

        return false
    }

    private fun tryLaunchSettingsIntent(intent: Intent): Boolean {
        return try {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            val resolver = intent.resolveActivity(packageManager)
            if (resolver == null) {
                false
            } else {
                startActivity(intent)
                true
            }
        } catch (e: Exception) {
            Log.w(TAG, "Battery settings intent failed: ${e.message}")
            false
        }
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
