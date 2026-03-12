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
            appWidgetManager.updateAppWidget(widgetId, buildSquareRemoteViews(context, snapshot))
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
            appWidgetManager.updateAppWidget(widgetId, buildWideRemoteViews(context, snapshot, compact))
        }
    }

    fun updateCircleWidgets(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        val snapshot = snapshot()
        for (widgetId in appWidgetIds) {
            appWidgetManager.updateAppWidget(widgetId, buildCircleRemoteViews(context, snapshot))
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
            if (browser.isConnected) return
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
        for (action in pending) action(controller)
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

        val squareIds = manager.getAppWidgetIds(ComponentName(context, SquareMusicWidgetProvider::class.java))
        if (squareIds.isNotEmpty()) updateSquareWidgets(context, manager, squareIds)

        val wideIds = manager.getAppWidgetIds(ComponentName(context, WideMusicWidgetProvider::class.java))
        if (wideIds.isNotEmpty()) updateWideWidgets(context, manager, wideIds)

        val circleIds = manager.getAppWidgetIds(ComponentName(context, CircleMusicWidgetProvider::class.java))
        if (circleIds.isNotEmpty()) updateCircleWidgets(context, manager, circleIds)
    }

    

    
    private fun buildSquareRemoteViews(context: Context, snapshot: WidgetSnapshot): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.widget_music_square)

        
        views.setInt(
            R.id.widget_root, "setBackgroundResource",
            if (snapshot.isPlaying) R.drawable.widget_bg_playing else R.drawable.widget_bg,
        )

        
        views.setTextViewText(R.id.widget_title, snapshot.title)
        views.setTextViewText(R.id.widget_artist, snapshot.artist)

        
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

        
        views.setImageViewResource(
            R.id.widget_btn_play_pause,
            if (snapshot.isPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
        )
        views.setInt(
            R.id.widget_btn_play_pause, "setBackgroundResource",
            if (snapshot.isPlaying) R.drawable.widget_play_pill_active else R.drawable.widget_play_pill,
        )
        
        views.setInt(R.id.widget_btn_play_pause, "setColorFilter", 0xFF1A1A2E.toInt())

        
        views.setInt(R.id.widget_btn_prev, "setColorFilter", 0xCCFFFFFF.toInt())
        views.setInt(R.id.widget_btn_next, "setColorFilter", 0xCCFFFFFF.toInt())

        
        views.setOnClickPendingIntent(R.id.widget_btn_prev,
            actionPendingIntent(context, SquareMusicWidgetProvider::class.java, ACTION_PREVIOUS))
        views.setOnClickPendingIntent(R.id.widget_btn_play_pause,
            actionPendingIntent(context, SquareMusicWidgetProvider::class.java, ACTION_TOGGLE_PLAYBACK))
        views.setOnClickPendingIntent(R.id.widget_btn_next,
            actionPendingIntent(context, SquareMusicWidgetProvider::class.java, ACTION_NEXT))
        views.setOnClickPendingIntent(R.id.widget_root,
            launchAppPendingIntent(context, SquareMusicWidgetProvider::class.java))

        
        views.setViewVisibility(R.id.widget_bg_art, View.GONE)
        val artBundle = resolveArtworkBundle(snapshot)
        if (artBundle != null) {
            views.setImageViewBitmap(R.id.widget_bg_art, artBundle.backdropSquare)
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

        
        views.setInt(
            R.id.widget_root, "setBackgroundResource",
            if (snapshot.isPlaying) R.drawable.widget_bg_playing else R.drawable.widget_bg,
        )

        
        views.setTextViewText(R.id.widget_title, snapshot.title)
        views.setTextViewText(R.id.widget_artist, snapshot.artist)

        
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

        
        views.setViewVisibility(R.id.widget_artist,
            if (compact) View.GONE else View.VISIBLE)
        views.setViewVisibility(R.id.widget_progress_text,
            if (compact) View.GONE else View.VISIBLE)
        views.setTextViewText(
            R.id.widget_progress_text,
            "${formatDuration(snapshot.positionMs)} / ${formatDuration(snapshot.durationMs)}",
        )

        
        views.setImageViewResource(
            R.id.widget_btn_play_pause,
            if (snapshot.isPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
        )
        views.setInt(
            R.id.widget_btn_play_pause, "setBackgroundResource",
            if (snapshot.isPlaying) R.drawable.widget_play_pill_active else R.drawable.widget_play_pill,
        )
        views.setInt(R.id.widget_btn_play_pause, "setColorFilter", 0xFF1A1A2E.toInt())

        
        views.setInt(R.id.widget_btn_prev, "setColorFilter", 0xCCFFFFFF.toInt())
        views.setInt(R.id.widget_btn_next, "setColorFilter", 0xCCFFFFFF.toInt())

        
        views.setOnClickPendingIntent(R.id.widget_btn_prev,
            actionPendingIntent(context, WideMusicWidgetProvider::class.java, ACTION_PREVIOUS))
        views.setOnClickPendingIntent(R.id.widget_btn_play_pause,
            actionPendingIntent(context, WideMusicWidgetProvider::class.java, ACTION_TOGGLE_PLAYBACK))
        views.setOnClickPendingIntent(R.id.widget_btn_next,
            actionPendingIntent(context, WideMusicWidgetProvider::class.java, ACTION_NEXT))
        views.setOnClickPendingIntent(R.id.widget_root,
            launchAppPendingIntent(context, WideMusicWidgetProvider::class.java))

        
        views.setViewVisibility(R.id.widget_bg_art, View.GONE)
        val artBundle = resolveArtworkBundle(snapshot)
        if (artBundle != null) {
            views.setImageViewBitmap(R.id.widget_bg_art, artBundle.backdropWide)
            views.setViewVisibility(R.id.widget_bg_art, View.VISIBLE)
        }

        return views
    }

    
    private fun buildCircleRemoteViews(context: Context, snapshot: WidgetSnapshot): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.widget_music_circle)

        
        views.setTextViewText(R.id.widget_title, snapshot.title)
        views.setTextViewText(R.id.widget_artist, snapshot.artist)

        
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

        
        views.setImageViewResource(
            R.id.widget_btn_play_pause,
            if (snapshot.isPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
        )
        views.setInt(
            R.id.widget_btn_play_pause, "setBackgroundResource",
            if (snapshot.isPlaying) R.drawable.widget_control_bg_play else R.drawable.widget_control_bg,
        )
        views.setInt(R.id.widget_btn_play_pause, "setColorFilter", 0xFFFFFFFF.toInt())

        
        views.setInt(R.id.widget_btn_prev, "setBackgroundResource", R.drawable.widget_control_bg)
        views.setInt(R.id.widget_btn_next, "setBackgroundResource", R.drawable.widget_control_bg)
        views.setInt(R.id.widget_btn_prev, "setColorFilter", 0xEEFFFFFF.toInt())
        views.setInt(R.id.widget_btn_next, "setColorFilter", 0xEEFFFFFF.toInt())

        
        views.setOnClickPendingIntent(R.id.widget_btn_prev,
            actionPendingIntent(context, CircleMusicWidgetProvider::class.java, ACTION_PREVIOUS))
        views.setOnClickPendingIntent(R.id.widget_btn_play_pause,
            actionPendingIntent(context, CircleMusicWidgetProvider::class.java, ACTION_TOGGLE_PLAYBACK))
        views.setOnClickPendingIntent(R.id.widget_btn_next,
            actionPendingIntent(context, CircleMusicWidgetProvider::class.java, ACTION_NEXT))
        views.setOnClickPendingIntent(R.id.widget_root,
            launchAppPendingIntent(context, CircleMusicWidgetProvider::class.java))

        
        val artBundle = resolveArtworkBundle(snapshot)
        if (artBundle != null) {
            views.setImageViewBitmap(R.id.widget_bg_art, artBundle.circle)
        } else {
            views.setImageViewResource(R.id.widget_bg_art, R.mipmap.ic_launcher)
        }

        return views
    }

    private fun resolveArtworkBundle(snapshot: WidgetSnapshot): ArtworkBundle? {
        val metadataBitmap = snapshot.artworkBitmap
        if (metadataBitmap != null) {
            val prepared = prepareArtworkBundle(metadataBitmap)
            if (snapshot.artworkUri.isNotEmpty()) putCachedArtwork(snapshot.artworkUri, prepared)
            return prepared
        }
        if (snapshot.artworkUri.isNotEmpty()) {
            val cached = getCachedArtwork(snapshot.artworkUri)
            if (cached != null) return cached
            queueArtworkLoad(snapshot.artworkUri)
        }
        return null
    }

    private fun getCachedArtwork(key: String): ArtworkBundle? {
        synchronized(artworkCache) { return artworkCache[key] }
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
                synchronized(artworkInFlight) { artworkInFlight.remove(uriString) }
            }
        }
    }

    private fun loadArtworkBundle(context: Context, uriString: String): ArtworkBundle? {
        val uri = Uri.parse(uriString)
        val decoded = when (uri.scheme?.lowercase()) {
            "content", "file" -> {
                context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it) }
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
                    connection.inputStream.use { BitmapFactory.decodeStream(it) }
                } finally {
                    connection.disconnect()
                }
            }
            else -> null
        } ?: return null
        return prepareArtworkBundle(decoded)
    }

    private fun prepareArtworkBundle(source: Bitmap): ArtworkBundle {
        val circle = prepareCircleBitmap(source, 320)
        val backdropSquare = prepareBackdropBitmap(source, 360, 360)
        val backdropWide = prepareBackdropBitmap(source, 540, 270)
        return ArtworkBundle(circle = circle, backdropSquare = backdropSquare, backdropWide = backdropWide)
    }

    
    private fun prepareCircleBitmap(bitmap: Bitmap, targetSizePx: Int): Bitmap {
        val w = bitmap.width
        val h = bitmap.height
        if (w <= 0 || h <= 0) return bitmap
        val minSide = minOf(w, h)
        val left = (w - minSide) / 2
        val top = (h - minSide) / 2
        val square = Bitmap.createBitmap(bitmap, left, top, minSide, minSide)
        val scaled = Bitmap.createScaledBitmap(square, targetSizePx, targetSizePx, true)
        val darkened = scaled.copy(Bitmap.Config.ARGB_8888, true)
        Canvas(darkened).drawColor(0x55000000)
        
        return applyRoundedCorners(darkened, targetSizePx / 2f)
    }

    
    private fun prepareBackdropBitmap(bitmap: Bitmap, targetWidth: Int, targetHeight: Int): Bitmap {
        val cropped = centerCropToAspect(bitmap, targetWidth.toFloat() / targetHeight.toFloat())
        val scaled = Bitmap.createScaledBitmap(cropped, targetWidth, targetHeight, true)
        val blurred = blurBackdropBitmap(scaled)
        val darkened = blurred.copy(Bitmap.Config.ARGB_8888, true)
        Canvas(darkened).drawColor(0x6E000000)
        val cardRadius = (minOf(targetWidth, targetHeight) * 0.18f).coerceAtLeast(12f)
        return applyRoundedCorners(darkened, cardRadius)
    }

    private fun blurBackdropBitmap(bitmap: Bitmap): Bitmap {
        val downscaled = Bitmap.createScaledBitmap(
            bitmap,
            (bitmap.width / 3).coerceAtLeast(1),
            (bitmap.height / 3).coerceAtLeast(1),
            true,
        )
        val downBlurred = boxBlur(downscaled, radius = 4)
        val upscaled = Bitmap.createScaledBitmap(downBlurred, bitmap.width, bitmap.height, true)
        return boxBlur(upscaled, radius = 6)
    }

    private fun boxBlur(bitmap: Bitmap, radius: Int): Bitmap {
        if (radius <= 0 || bitmap.width <= 1 || bitmap.height <= 1) {
            return bitmap.copy(Bitmap.Config.ARGB_8888, true)
        }

        val width = bitmap.width
        val height = bitmap.height
        val source = IntArray(width * height)
        bitmap.getPixels(source, 0, width, 0, 0, width, height)

        val horizontal = IntArray(width * height)
        val output = IntArray(width * height)
        val windowSize = (radius * 2) + 1

        for (y in 0 until height) {
            var a = 0
            var r = 0
            var g = 0
            var b = 0
            val rowStart = y * width

            for (i in -radius..radius) {
                val x = i.coerceIn(0, width - 1)
                val color = source[rowStart + x]
                a += color ushr 24
                r += color shr 16 and 0xFF
                g += color shr 8 and 0xFF
                b += color and 0xFF
            }

            for (x in 0 until width) {
                horizontal[rowStart + x] =
                    ((a / windowSize) shl 24) or
                    ((r / windowSize) shl 16) or
                    ((g / windowSize) shl 8) or
                    (b / windowSize)

                val removeX = (x - radius).coerceIn(0, width - 1)
                val addX = (x + radius + 1).coerceIn(0, width - 1)
                val removeColor = source[rowStart + removeX]
                val addColor = source[rowStart + addX]

                a += (addColor ushr 24) - (removeColor ushr 24)
                r += ((addColor shr 16) and 0xFF) - ((removeColor shr 16) and 0xFF)
                g += ((addColor shr 8) and 0xFF) - ((removeColor shr 8) and 0xFF)
                b += (addColor and 0xFF) - (removeColor and 0xFF)
            }
        }

        for (x in 0 until width) {
            var a = 0
            var r = 0
            var g = 0
            var b = 0

            for (i in -radius..radius) {
                val y = i.coerceIn(0, height - 1)
                val color = horizontal[(y * width) + x]
                a += color ushr 24
                r += color shr 16 and 0xFF
                g += color shr 8 and 0xFF
                b += color and 0xFF
            }

            for (y in 0 until height) {
                output[(y * width) + x] =
                    ((a / windowSize) shl 24) or
                    ((r / windowSize) shl 16) or
                    ((g / windowSize) shl 8) or
                    (b / windowSize)

                val removeY = (y - radius).coerceIn(0, height - 1)
                val addY = (y + radius + 1).coerceIn(0, height - 1)
                val removeColor = horizontal[(removeY * width) + x]
                val addColor = horizontal[(addY * width) + x]

                a += (addColor ushr 24) - (removeColor ushr 24)
                r += ((addColor shr 16) and 0xFF) - ((removeColor shr 16) and 0xFF)
                g += ((addColor shr 8) and 0xFF) - ((removeColor shr 8) and 0xFF)
                b += (addColor and 0xFF) - (removeColor and 0xFF)
            }
        }

        return Bitmap.createBitmap(output, width, height, Bitmap.Config.ARGB_8888)
    }

    private fun centerCropToAspect(bitmap: Bitmap, targetAspect: Float): Bitmap {
        val w = bitmap.width
        val h = bitmap.height
        if (w <= 0 || h <= 0) return bitmap
        val sourceAspect = w.toFloat() / h.toFloat()
        return if (sourceAspect > targetAspect) {
            val cropWidth = (h * targetAspect).toInt().coerceIn(1, w)
            val left = ((w - cropWidth) / 2).coerceAtLeast(0)
            Bitmap.createBitmap(bitmap, left, 0, cropWidth, h)
        } else {
            val cropHeight = (w / targetAspect).toInt().coerceIn(1, h)
            val top = ((h - cropHeight) / 2).coerceAtLeast(0)
            Bitmap.createBitmap(bitmap, 0, top, w, cropHeight)
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

    private fun actionPendingIntent(
        context: Context,
        providerClass: Class<out android.appwidget.AppWidgetProvider>,
        action: String,
    ): PendingIntent {
        val intent = Intent(context, providerClass).apply { this.action = action }
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
        } else 0
        val isPlaying = playbackState?.state == PlaybackStateCompat.STATE_PLAYING ||
            playbackState?.state == PlaybackStateCompat.STATE_BUFFERING
        val artworkUri = metadata?.description?.iconUri?.toString()?.trim().orEmpty()
        val artworkBitmap = metadata?.getBitmap(MediaMetadataCompat.METADATA_KEY_ART)
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

    private fun resolvePlaybackPosition(state: PlaybackStateCompat?, durationMs: Long): Long {
        if (state == null) return 0L
        var position = state.position.coerceAtLeast(0L)
        if (state.state == PlaybackStateCompat.STATE_PLAYING) {
            val elapsedMs = (SystemClock.elapsedRealtime() - state.lastPositionUpdateTime).coerceAtLeast(0L)
            position += (elapsedMs * state.playbackSpeed).toLong()
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
        val circle: Bitmap,          
        val backdropSquare: Bitmap,  
        val backdropWide: Bitmap,    
    )
}
