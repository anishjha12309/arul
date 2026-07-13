package com.hsrapps.arul

import com.hsrapps.arul.feedvideo.FeedVideoPlugin
import com.hsrapps.arul.feedvideo.VideoThumbnailChannel
import com.hsrapps.arul.wallpaper.WallpaperApplyChannel
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity, not FlutterActivity: the PhonePe Payment SDK requires it,
// and switching later would mean re-testing the whole activity lifecycle. Costs nothing now.
class MainActivity : FlutterFragmentActivity() {

    private var wallpaperApplyChannel: WallpaperApplyChannel? = null
    private var feedVideoPlugin: FeedVideoPlugin? = null
    private var videoThumbnailChannel: VideoThumbnailChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // In-feed live previews — native Media3 ExoPlayer texture pool. The Dart
        // VideoPreloadController drives a small reuse pool of these players, each
        // rendering into a Flutter Texture via a SurfaceProducer. A live wallpaper
        // that has been APPLIED runs in its own WallpaperService (see wallpaper/),
        // which this plugin does not touch.
        feedVideoPlugin = FeedVideoPlugin(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
            flutterEngine.renderer,
        )

        // Wallpaper apply (static + live).
        val applyChannel = WallpaperApplyChannel(applicationContext)
        wallpaperApplyChannel = applyChannel
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            WallpaperApplyChannel.CHANNEL,
        ).setMethodCallHandler(applyChannel)

        // Grid fallback: a live item whose pre-generated thumbnail is missing (a
        // newly published clip, say) still needs a still. This pulls its first
        // frame natively instead of spinning up a decoder per grid tile.
        val thumbs = VideoThumbnailChannel(applicationContext)
        videoThumbnailChannel = thumbs
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            VideoThumbnailChannel.CHANNEL,
        ).setMethodCallHandler(thumbs)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // A destroyed engine must leave no dangling coroutine jobs, ExoPlayers or
        // SurfaceProducers behind.
        wallpaperApplyChannel?.dispose()
        wallpaperApplyChannel = null
        feedVideoPlugin?.dispose()
        feedVideoPlugin = null
        videoThumbnailChannel?.dispose()
        videoThumbnailChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
