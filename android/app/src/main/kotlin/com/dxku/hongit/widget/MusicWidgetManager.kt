package com.dxku.hongit.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.support.v4.media.MediaBrowserCompat
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaControllerCompat
import android.support.v4.media.session.PlaybackStateCompat
import android.view.View
import android.widget.RemoteViews
import com.dxku.hongit.MainActivity
import com.dxku.hongit.R
import com.ryanheise.audioservice.AudioService
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

object MusicWidgetManager {
    const val ACTION_PREVIOUS = "com.dxku.hongit.widget.ACTION_PREVIOUS"
    const val ACTION_TOGGLE_PLAYBACK = "com.dxku.hongit.widget.ACTION_TOGGLE_PLAYBACK"
    const val ACTION_NEXT = "com.dxku.hongit.widget.ACTION_NEXT"
    const val ACTION_REFRESH = "com.dxku.hongit.widget.ACTION_REFRESH"

    private val mainHandler = Handler(Looper.getMainLooper())
    private var appContext: Context? = null
    private var mediaBrowser: MediaBrowserCompat? = null
    private var mediaController: MediaControllerCompat? = null
    private var isConnecting = false
    private var callbackRegistered = false
    private var lastWidgetUpdateMs = 0L
    private var scheduledUpdate = false
    private val pendingControllerActions = mutableListOf<(MediaControllerCompat?) -> Unit>()
    private val artworkExecutor = Executors.newSingleThreadExecutor()
    private val artworkCache = LinkedHashMap<String, ArtworkBundle>(24, 0.75f, true)
    private val artworkInFlight = mutableSetOf<String>()

    private val mediaControllerCallback = object : MediaControllerCompat.Callback() {
        override fun onPlaybackStateChanged(state: PlaybackStateCompat?) {
            scheduleWidgetUpdate(force = false)
        }

        override fun onMetadataChanged(metadata: MediaMetadataCompat?) {
            scheduleWidgetUpdate(force = true)
        }
    }

    private val browserConnectionCallback = object : MediaBrowserCompat.ConnectionCallback() {
        override fun onConnected() {
            isConnecting = false
            val context = appContext ?: return
            val token = mediaBrowser?.sessionToken
            if (token == null) {
                flushPendingControllerActions(null)
                return
            }

            try {
                val controller = MediaControllerCompat(context, token)
                mediaController = controller
                if (!callbackRegistered) {
                    controller.registerCallback(mediaControllerCallback)
                    callbackRegistered = true
                }
                flushPendingControllerActions(controller)
                scheduleWidgetUpdate(force = true)
            } catch (_: Throwable) {
                flushPendingControllerActions(null)
            }
        }

        override fun onConnectionSuspended() {
            isConnecting = false
            clearController()
            flushPendingControllerActions(null)
            scheduleWidgetUpdate(force = true)
        }

        override fun onConnectionFailed() {
            isConnecting = false
            clearController()
            flushPendingControllerActions(null)
            scheduleWidgetUpdate(force = true)
        }
    }

    fun initialize(context: Context) {
        appContext = context.applicationContext
        ensureConnected()
        scheduleWidgetUpdate(force = true)
    }

    fun handleProviderIntent(context: Context, intent: Intent?) {
        initialize(context)
        when (intent?.action) {
            ACTION_PREVIOUS -> dispatchTransportControl { it.skipToPrevious() }
            ACTION_TOGGLE_PLAYBACK -> dispatchTogglePlayback()
            ACTION_NEXT -> dispatchTransportControl { it.skipToNext() }
            ACTION_REFRESH,
            AppWidgetManager.ACTION_APPWIDGET_UPDATE -> scheduleWidgetUpdate(force = true)
        }
    }

    fun updateSquareWidgets(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        val snapshot = snapshot()
        for (widgetId in appWidgetIds) {
            val views = buildSquareRemoteViews(context, snapshot)
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }

    fun updateWideWidgets(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        val snapshot = snapshot()
        for (widgetId in appWidgetIds) {
            val options = appWidgetManager.getAppWidgetOptions(widgetId)
            val compact = isCompactWide(options)
            val views = buildWideRemoteViews(context, snapshot, compact)
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }

    private fun isCompactWide(options: Bundle): Boolean {
        val minWidthDp = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 250)
        return minWidthDp in 1..220
    }

    private fun dispatchTransportControl(action: (MediaControllerCompat.TransportControls) -> Unit) {
        withController { controller ->
            val controls = controller?.transportControls ?: return@withController
            action(controls)
            scheduleWidgetUpdate(force = true)
        }
    }

    private fun dispatchTogglePlayback() {
        withController { controller ->
            val controls = controller?.transportControls ?: return@withController
            val state = controller.playbackState?.state
            if (state == PlaybackStateCompat.STATE_PLAYING ||
                state == PlaybackStateCompat.STATE_BUFFERING
            ) {
                controls.pause()
            } else {
                controls.play()
            }
            scheduleWidgetUpdate(force = true)
        }
    }

    private fun withController(block: (MediaControllerCompat?) -> Unit) {
        val controller = mediaController
        if (controller != null) {
            block(controller)
            return
        }
        pendingControllerActions.add(block)
        ensureConnected()
    }

    private fun ensureConnected() {
        val context = appContext ?: return
        if (mediaController != null) return
        if (isConnecting) return

        val browser = mediaBrowser
        if (browser != null) {
            if (browser.isConnected) {
                return
            }
            try {
                browser.disconnect()
            } catch (_: Throwable) {
            }
        }

        isConnecting = true
        mediaBrowser = MediaBrowserCompat(
            context,
            ComponentName(context, AudioService::class.java),
            browserConnectionCallback,
            null,
        ).also { it.connect() }
    }

    private fun clearController() {
        val controller = mediaController
        if (controller != null && callbackRegistered) {
            try {
                controller.unregisterCallback(mediaControllerCallback)
            } catch (_: Throwable) {
            }
        }
        callbackRegistered = false
        mediaController = null
    }

    private fun flushPendingControllerActions(controller: MediaControllerCompat?) {
        if (pendingControllerActions.isEmpty()) return
        val pending = pendingControllerActions.toList()
        pendingControllerActions.clear()
        for (action in pending) {
            action(controller)
        }
    }

    private fun scheduleWidgetUpdate(force: Boolean) {
        val context = appContext ?: return
        val now = SystemClock.elapsedRealtime()
        val minGapMs = 1000L
        val elapsed = now - lastWidgetUpdateMs

        if (force || elapsed >= minGapMs) {
            runWidgetUpdate(context)
            return
        }

        if (scheduledUpdate) return
        scheduledUpdate = true
        mainHandler.postDelayed({
            scheduledUpdate = false
            runWidgetUpdate(context)
        }, minGapMs - elapsed)
    }

    private fun runWidgetUpdate(context: Context) {
        lastWidgetUpdateMs = SystemClock.elapsedRealtime()
        ensureConnected()
        val manager = AppWidgetManager.getInstance(context)

        val squareIds = manager.getAppWidgetIds(
            ComponentName(context, SquareMusicWidgetProvider::class.java),
        )
        if (squareIds.isNotEmpty()) {
            updateSquareWidgets(context, manager, squareIds)
        }

        val wideIds = manager.getAppWidgetIds(
            ComponentName(context, WideMusicWidgetProvider::class.java),
        )
        if (wideIds.isNotEmpty()) {
            updateWideWidgets(context, manager, wideIds)
        }
    }

    private fun buildSquareRemoteViews(context: Context, snapshot: WidgetSnapshot): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.widget_music_square)
        bindCoreViews(
            context = context,
            views = views,
            snapshot = snapshot,
            providerClass = SquareMusicWidgetProvider::class.java,
        )
        views.setImageViewResource(R.id.widget_cover, R.mipmap.ic_launcher)
        views.setViewVisibility(R.id.widget_bg_art, View.GONE)
        val artBundle = resolveArtworkBundle(snapshot)
        if (artBundle != null) {
            views.setImageViewBitmap(R.id.widget_cover, artBundle.cover)
            views.setImageViewBitmap(R.id.widget_bg_art, artBundle.backdrop)
            views.setViewVisibility(R.id.widget_bg_art, View.VISIBLE)
        }
        return views
    }

    private fun buildWideRemoteViews(
        context: Context,
        snapshot: WidgetSnapshot,
        compact: Boolean,
    ): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.widget_music_wide)
        bindCoreViews(
            context = context,
            views = views,
            snapshot = snapshot,
            providerClass = WideMusicWidgetProvider::class.java,
        )
        views.setImageViewResource(R.id.widget_cover, R.mipmap.ic_launcher)
        views.setViewVisibility(R.id.widget_bg_art, View.GONE)

        val artBundle = resolveArtworkBundle(snapshot)
        if (artBundle != null) {
            views.setImageViewBitmap(R.id.widget_cover, artBundle.cover)
            views.setImageViewBitmap(R.id.widget_bg_art, artBundle.backdrop)
            views.setViewVisibility(R.id.widget_bg_art, View.VISIBLE)
        }

        views.setProgressBar(R.id.widget_progress_playing, 1000, snapshot.progressScaled, false)
        views.setProgressBar(R.id.widget_progress_paused, 1000, snapshot.progressScaled, false)
        views.setViewVisibility(
            R.id.widget_progress_playing,
            if (snapshot.isPlaying) View.VISIBLE else View.GONE,
        )
        views.setViewVisibility(
            R.id.widget_progress_paused,
            if (snapshot.isPlaying) View.GONE else View.VISIBLE,
        )
        views.setViewVisibility(
            R.id.widget_artist,
            if (compact) View.GONE else View.VISIBLE,
        )
        views.setViewVisibility(
            R.id.widget_progress_text,
            if (compact) View.GONE else View.VISIBLE,
        )
        views.setTextViewText(
            R.id.widget_progress_text,
            "${formatDuration(snapshot.positionMs)} / ${formatDuration(snapshot.durationMs)}",
        )
        return views
    }

    private fun bindCoreViews(
        context: Context,
        views: RemoteViews,
        snapshot: WidgetSnapshot,
        providerClass: Class<out android.appwidget.AppWidgetProvider>,
    ) {
        views.setInt(
            R.id.widget_root,
            "setBackgroundResource",
            if (snapshot.isPlaying) R.drawable.widget_bg_playing else R.drawable.widget_bg,
        )
        views.setTextViewText(R.id.widget_title, snapshot.title)
        views.setTextViewText(R.id.widget_artist, snapshot.artist)
        views.setTextColor(R.id.widget_title, if (snapshot.isPlaying) 0xFFFFFFFF.toInt() else 0xFFF3F5FF.toInt())
        views.setTextColor(R.id.widget_artist, if (snapshot.isPlaying) 0xFFCFFEF1.toInt() else 0xFFCFE1EA.toInt())
        views.setImageViewResource(
            R.id.widget_btn_play_pause,
            if (snapshot.isPlaying) android.R.drawable.ic_media_pause
            else android.R.drawable.ic_media_play,
        )
        views.setInt(
            R.id.widget_btn_play_pause,
            "setBackgroundResource",
            if (snapshot.isPlaying) R.drawable.widget_control_bg_play else R.drawable.widget_control_bg,
        )
        views.setInt(R.id.widget_btn_prev, "setBackgroundResource", R.drawable.widget_control_bg)
        views.setInt(R.id.widget_btn_next, "setBackgroundResource", R.drawable.widget_control_bg)
        views.setInt(
            R.id.widget_btn_play_pause,
            "setColorFilter",
            if (snapshot.isPlaying) 0xFF082028.toInt() else 0xFFFFFFFF.toInt(),
        )
        val sideColor = if (snapshot.isPlaying) 0xFFA9FFF0.toInt() else 0xFFE9EDFF.toInt()
        views.setInt(R.id.widget_btn_prev, "setColorFilter", sideColor)
        views.setInt(R.id.widget_btn_next, "setColorFilter", sideColor)

        views.setOnClickPendingIntent(
            R.id.widget_btn_prev,
            actionPendingIntent(context, providerClass, ACTION_PREVIOUS),
        )
        views.setOnClickPendingIntent(
            R.id.widget_btn_play_pause,
            actionPendingIntent(context, providerClass, ACTION_TOGGLE_PLAYBACK),
        )
        views.setOnClickPendingIntent(
            R.id.widget_btn_next,
            actionPendingIntent(context, providerClass, ACTION_NEXT),
        )
        views.setOnClickPendingIntent(
            R.id.widget_root,
            launchAppPendingIntent(context, providerClass),
        )
    }

    private fun resolveArtworkBundle(snapshot: WidgetSnapshot): ArtworkBundle? {
        val metadataBitmap = snapshot.artworkBitmap
        if (metadataBitmap != null) {
            val prepared = prepareArtworkBundle(metadataBitmap)
            if (snapshot.artworkUri.isNotEmpty()) {
                putCachedArtwork(snapshot.artworkUri, prepared)
            }
            return prepared
        }

        if (snapshot.artworkUri.isNotEmpty()) {
            val cached = getCachedArtwork(snapshot.artworkUri)
            if (cached != null) return cached
            queueArtworkLoad(snapshot.artworkUri)
        }
        return null
    }

    private fun actionPendingIntent(
        context: Context,
        providerClass: Class<out android.appwidget.AppWidgetProvider>,
        action: String,
    ): PendingIntent {
        val intent = Intent(context, providerClass).apply {
            this.action = action
        }
        return PendingIntent.getBroadcast(
            context,
            (providerClass.name + action).hashCode(),
            intent,
            pendingIntentFlags(),
        )
    }

    private fun launchAppPendingIntent(
        context: Context,
        providerClass: Class<out android.appwidget.AppWidgetProvider>,
    ): PendingIntent {
        val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: Intent(context, MainActivity::class.java)
        intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        return PendingIntent.getActivity(
            context,
            (providerClass.name + "launch").hashCode(),
            intent,
            pendingIntentFlags(),
        )
    }

    private fun pendingIntentFlags(): Int {
        val base = PendingIntent.FLAG_UPDATE_CURRENT
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            base or PendingIntent.FLAG_IMMUTABLE
        } else {
            base
        }
    }

    private fun snapshot(): WidgetSnapshot {
        val controller = mediaController
        val metadata = controller?.metadata
        val playbackState = controller?.playbackState

        val rawTitle = metadata?.description?.title?.toString()?.trim().orEmpty()
        val rawArtist = metadata?.description?.subtitle?.toString()?.trim().orEmpty()
        val hasTrack = rawTitle.isNotEmpty()

        val title = if (hasTrack) rawTitle else "Not playing"
        val artist = if (hasTrack) rawArtist.ifEmpty { "Unknown artist" } else "Tap to open Hongeet"

        val duration = (metadata?.getLong(MediaMetadataCompat.METADATA_KEY_DURATION) ?: 0L)
            .coerceAtLeast(0L)
        val position = resolvePlaybackPosition(playbackState, duration)
        val progressScaled = if (duration > 0) {
            ((position * 1000L) / duration).toInt().coerceIn(0, 1000)
        } else {
            0
        }
        val isPlaying = playbackState?.state == PlaybackStateCompat.STATE_PLAYING ||
            playbackState?.state == PlaybackStateCompat.STATE_BUFFERING
        val artworkUri = metadata?.description?.iconUri?.toString()?.trim().orEmpty()
        val artworkBitmap =
            metadata?.getBitmap(MediaMetadataCompat.METADATA_KEY_ART)
                ?: metadata?.getBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART)

        return WidgetSnapshot(
            title = title,
            artist = artist,
            isPlaying = isPlaying,
            positionMs = position,
            durationMs = duration,
            progressScaled = progressScaled,
            artworkUri = artworkUri,
            artworkBitmap = artworkBitmap,
        )
    }

    private fun getCachedArtwork(key: String): ArtworkBundle? {
        synchronized(artworkCache) {
            return artworkCache[key]
        }
    }

    private fun putCachedArtwork(key: String, bundle: ArtworkBundle) {
        synchronized(artworkCache) {
            artworkCache[key] = bundle
            while (artworkCache.size > 24) {
                val firstKey = artworkCache.entries.firstOrNull()?.key ?: break
                artworkCache.remove(firstKey)
            }
        }
    }

    private fun queueArtworkLoad(uriString: String) {
        if (uriString.isBlank()) return
        val context = appContext ?: return
        synchronized(artworkInFlight) {
            if (!artworkInFlight.add(uriString)) return
        }

        artworkExecutor.execute {
            try {
                val bundle = loadArtworkBundle(context, uriString) ?: return@execute
                putCachedArtwork(uriString, bundle)
                scheduleWidgetUpdate(force = true)
            } finally {
                synchronized(artworkInFlight) {
                    artworkInFlight.remove(uriString)
                }
            }
        }
    }

    private fun loadArtworkBundle(context: Context, uriString: String): ArtworkBundle? {
        val uri = Uri.parse(uriString)
        val decoded = when (uri.scheme?.lowercase()) {
            "content", "file" -> {
                context.contentResolver.openInputStream(uri)?.use { stream ->
                    BitmapFactory.decodeStream(stream)
                }
            }
            "http", "https" -> {
                val connection = (URL(uriString).openConnection() as? HttpURLConnection) ?: return null
                connection.connectTimeout = 4000
                connection.readTimeout = 7000
                connection.instanceFollowRedirects = true
                connection.setRequestProperty("User-Agent", "Mozilla/5.0")
                try {
                    connection.connect()
                    if (connection.responseCode !in 200..299) return null
                    connection.inputStream.use { stream ->
                        BitmapFactory.decodeStream(stream)
                    }
                } finally {
                    connection.disconnect()
                }
            }
            else -> null
        } ?: return null

        return prepareArtworkBundle(decoded)
    }

    private fun prepareArtworkBundle(source: Bitmap): ArtworkBundle {
        val cover = prepareCoverBitmap(source, 180)
        val backdrop = prepareBackdropBitmap(source, 320, 160)
        return ArtworkBundle(cover = cover, backdrop = backdrop)
    }

    private fun prepareCoverBitmap(bitmap: Bitmap, targetSizePx: Int): Bitmap {
        val width = bitmap.width
        val height = bitmap.height
        if (width <= 0 || height <= 0) return bitmap

        val minSide = minOf(width, height)
        val zoom = 1.18f
        val cropSide = (minSide / zoom).toInt().coerceIn(1, minSide)
        val left = ((width - cropSide) / 2).coerceAtLeast(0)
        val top = ((height - cropSide) / 2).coerceAtLeast(0)
        val square = Bitmap.createBitmap(bitmap, left, top, cropSide, cropSide)
        val scaled = if (cropSide == targetSizePx) {
            square
        } else {
            Bitmap.createScaledBitmap(square, targetSizePx, targetSizePx, true)
        }
        return applyRoundedCorners(scaled, targetSizePx * 0.16f)
    }

    private fun prepareBackdropBitmap(
        bitmap: Bitmap,
        targetWidth: Int,
        targetHeight: Int,
    ): Bitmap {
        val cropped = centerCropToAspect(bitmap, targetWidth.toFloat() / targetHeight.toFloat())
        val scaled = Bitmap.createScaledBitmap(cropped, targetWidth, targetHeight, true)
        val blurSeed = Bitmap.createScaledBitmap(
            scaled,
            (targetWidth / 14).coerceAtLeast(1),
            (targetHeight / 14).coerceAtLeast(1),
            true,
        )
        val blurred = Bitmap.createScaledBitmap(blurSeed, targetWidth, targetHeight, true)
        val out = blurred.copy(Bitmap.Config.RGB_565, true)
        val canvas = Canvas(out)
        canvas.drawColor(0x76000000)
        return out
    }

    private fun centerCropToAspect(bitmap: Bitmap, targetAspect: Float): Bitmap {
        val width = bitmap.width
        val height = bitmap.height
        if (width <= 0 || height <= 0) return bitmap
        val sourceAspect = width.toFloat() / height.toFloat()
        return if (sourceAspect > targetAspect) {
            val cropWidth = (height * targetAspect).toInt().coerceIn(1, width)
            val left = ((width - cropWidth) / 2).coerceAtLeast(0)
            Bitmap.createBitmap(bitmap, left, 0, cropWidth, height)
        } else {
            val cropHeight = (width / targetAspect).toInt().coerceIn(1, height)
            val top = ((height - cropHeight) / 2).coerceAtLeast(0)
            Bitmap.createBitmap(bitmap, 0, top, width, cropHeight)
        }
    }

    private fun applyRoundedCorners(bitmap: Bitmap, radius: Float): Bitmap {
        val output = Bitmap.createBitmap(bitmap.width, bitmap.height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(output)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            shader = BitmapShader(bitmap, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
        }
        val rect = RectF(0f, 0f, bitmap.width.toFloat(), bitmap.height.toFloat())
        canvas.drawRoundRect(rect, radius, radius, paint)
        return output
    }

    private fun resolvePlaybackPosition(
        state: PlaybackStateCompat?,
        durationMs: Long,
    ): Long {
        if (state == null) return 0L
        var position = state.position.coerceAtLeast(0L)
        if (state.state == PlaybackStateCompat.STATE_PLAYING) {
            val elapsedMs = (SystemClock.elapsedRealtime() - state.lastPositionUpdateTime)
                .coerceAtLeast(0L)
            val speed = state.playbackSpeed
            position += (elapsedMs * speed).toLong()
        }
        if (durationMs <= 0L) return position
        return position.coerceIn(0L, durationMs)
    }

    private fun formatDuration(ms: Long): String {
        val safeMs = ms.coerceAtLeast(0L)
        val totalSeconds = safeMs / 1000L
        val hours = totalSeconds / 3600L
        val minutes = (totalSeconds % 3600L) / 60L
        val seconds = totalSeconds % 60L
        return if (hours > 0L) {
            "$hours:${minutes.toString().padStart(2, '0')}:${seconds.toString().padStart(2, '0')}"
        } else {
            "$minutes:${seconds.toString().padStart(2, '0')}"
        }
    }

    private data class WidgetSnapshot(
        val title: String,
        val artist: String,
        val isPlaying: Boolean,
        val positionMs: Long,
        val durationMs: Long,
        val progressScaled: Int,
        val artworkUri: String,
        val artworkBitmap: Bitmap?,
    )

    private data class ArtworkBundle(
        val cover: Bitmap,
        val backdrop: Bitmap,
    )
}
