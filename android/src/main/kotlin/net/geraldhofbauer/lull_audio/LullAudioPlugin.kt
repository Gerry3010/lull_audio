package net.geraldhofbauer.lull_audio

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.google.common.util.concurrent.MoreExecutors
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.io.File

/**
 * lull_audio Android: drives a Media3 ExoPlayer (hosted by [PlaybackService]) via
 * a MediaController, so playback is reflected in the system media notification /
 * lock-screen controls. Pushes playback state on the `lull_audio/events` channel.
 */
class LullAudioPlugin :
    FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var channel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var context: Context
    private var events: EventChannel.EventSink? = null
    private var controller: MediaController? = null
    private val main = Handler(Looper.getMainLooper())
    private var ticker: Runnable? = null

    private var npTitle: String? = null
    private var npArtist: String? = null
    private var npArtUri: String? = null

    private val tempFiles = mutableListOf<File>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "lull_audio")
        channel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "lull_audio/events")
        eventChannel.setStreamHandler(this)

        val token = SessionToken(
            context, ComponentName(context, PlaybackService::class.java)
        )
        val future = MediaController.Builder(context, token).buildAsync()
        future.addListener({
            controller = future.get().also { it.addListener(playerListener) }
        }, MoreExecutors.directExecutor())
    }

    // ─── Player listener + state ─────────────────────────────────────────────

    private val playerListener = object : Player.Listener {
        override fun onEvents(player: Player, events: Player.Events) {
            sendState()
        }
    }

    private fun sendState() {
        val c = controller ?: return
        val sink = events ?: return
        val dur = c.duration
        val map = hashMapOf<String, Any?>(
            "type" to "state",
            "positionMs" to c.currentPosition.coerceAtLeast(0),
            "isPlaying" to c.isPlaying,
            "processingState" to when (c.playbackState) {
                Player.STATE_BUFFERING -> 2
                Player.STATE_READY -> 3
                Player.STATE_ENDED -> 4
                else -> 0
            },
            "currentChunkIndex" to c.currentMediaItemIndex,
        )
        if (dur != C.TIME_UNSET) map["durationMs"] = dur
        sink.success(map)
    }

    private fun startTicker() {
        if (ticker != null) return
        ticker = object : Runnable {
            override fun run() {
                sendState()
                main.postDelayed(this, 500)
            }
        }.also { main.post(it) }
    }

    private fun stopTicker() {
        ticker?.let { main.removeCallbacks(it) }
        ticker = null
    }

    // ─── Source → MediaItem ──────────────────────────────────────────────────

    private fun metadata(): MediaMetadata {
        val b = MediaMetadata.Builder()
        npTitle?.let { b.setTitle(it) }
        npArtist?.let { b.setArtist(it) }
        npArtUri?.let { b.setArtworkUri(Uri.parse(it)) }
        return b.build()
    }

    @Suppress("UNCHECKED_CAST")
    private fun buildMediaItem(args: Any?): MediaItem? {
        val map = args as? Map<String, Any?> ?: return null
        val uri = when (map["kind"]) {
            "url" -> (map["url"] as? String)?.let { Uri.parse(it) }
            "file" -> (map["path"] as? String)?.let { Uri.fromFile(File(it)) }
            "asset" -> (map["asset"] as? String)?.let {
                Uri.parse("asset:///flutter_assets/$it")
            }
            "bytes" -> {
                val bytes = map["bytes"] as? ByteArray ?: return null
                val f = File.createTempFile("lull_audio", ".bin", context.cacheDir)
                f.writeBytes(bytes)
                tempFiles.add(f)
                Uri.fromFile(f)
            }
            else -> null
        } ?: return null
        return MediaItem.Builder().setUri(uri).setMediaMetadata(metadata()).build()
    }

    // ─── Method calls ────────────────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: Result) {
        val c = controller
        when (call.method) {
            "getPlatformVersion" ->
                return result.success("Android ${android.os.Build.VERSION.RELEASE}")
            "setSource" -> {
                val item = buildMediaItem(call.arguments)
                if (c != null && item != null) {
                    c.setMediaItem(item)
                    c.prepare()
                }
            }
            "enqueue" -> {
                val item = buildMediaItem(call.arguments)
                if (c != null && item != null) {
                    if (c.mediaItemCount == 0) {
                        c.setMediaItem(item); c.prepare()
                    } else {
                        c.addMediaItem(item)
                    }
                }
            }
            "clearQueue" -> c?.clearMediaItems()
            "play" -> c?.play()
            "pause" -> c?.pause()
            "stop" -> c?.stop()
            "seek" -> call.argument<Int>("positionMs")?.let { c?.seekTo(it.toLong()) }
            "skipToNext" -> c?.seekToNextMediaItem()
            "skipToPrevious" -> c?.seekToPreviousMediaItem()
            "setNowPlaying" -> {
                npTitle = call.argument("title")
                npArtist = call.argument("artist")
                npArtUri = call.argument("artworkUri")
                // Apply to the current item so the notification updates live.
                if (c != null && c.currentMediaItem != null) {
                    val pos = c.currentPosition
                    val updated = c.currentMediaItem!!.buildUpon()
                        .setMediaMetadata(metadata()).build()
                    c.replaceMediaItem(c.currentMediaItemIndex, updated)
                    c.seekTo(pos)
                }
            }
            "clearNowPlaying" -> { npTitle = null; npArtist = null; npArtUri = null }
            else -> return result.notImplemented()
        }
        result.success(null)
    }

    // ─── Event channel ───────────────────────────────────────────────────────

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        events = sink
        startTicker()
    }

    override fun onCancel(arguments: Any?) {
        stopTicker()
        events = null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopTicker()
        channel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        controller?.removeListener(playerListener)
        controller?.release()
        controller = null
        tempFiles.forEach { runCatching { it.delete() } }
        tempFiles.clear()
    }
}
