import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'lull_audio_method_channel.dart';
import 'src/lull_source.dart';
import 'src/lull_state.dart';
import 'src/now_playing_info.dart';

/// The interface that platform implementations of `lull_audio` must implement.
///
/// One logical player + Now-Playing surface per app (single-instance for v1).
abstract class LullAudioPlatform extends PlatformInterface {
  LullAudioPlatform() : super(token: _token);

  static final Object _token = Object();

  static LullAudioPlatform _instance = MethodChannelLullAudio();

  static LullAudioPlatform get instance => _instance;

  static set instance(LullAudioPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Platform/OS version string — handy for probing during bring-up.
  Future<String?> getPlatformVersion() {
    throw UnimplementedError('getPlatformVersion() has not been implemented.');
  }

  // ─── Source / queue ────────────────────────────────────────────────────────

  /// Replaces the current item with [source] and resets the chunk queue.
  Future<void> setSource(LullSource source) {
    throw UnimplementedError('setSource() has not been implemented.');
  }

  /// Appends [source] to the gapless chunk queue (for sequential byte chunks).
  Future<void> enqueue(LullSource source) {
    throw UnimplementedError('enqueue() has not been implemented.');
  }

  /// Clears the queue and stops playback.
  Future<void> clearQueue() {
    throw UnimplementedError('clearQueue() has not been implemented.');
  }

  // ─── Transport ─────────────────────────────────────────────────────────────

  Future<void> play() => throw UnimplementedError('play()');
  Future<void> pause() => throw UnimplementedError('pause()');
  Future<void> stop() => throw UnimplementedError('stop()');
  Future<void> seek(Duration position) => throw UnimplementedError('seek()');
  Future<void> skipToNext() => throw UnimplementedError('skipToNext()');
  Future<void> skipToPrevious() => throw UnimplementedError('skipToPrevious()');

  // ─── Now-Playing ───────────────────────────────────────────────────────────

  Future<void> setNowPlaying(NowPlayingInfo info) {
    throw UnimplementedError('setNowPlaying() has not been implemented.');
  }

  Future<void> clearNowPlaying() {
    throw UnimplementedError('clearNowPlaying() has not been implemented.');
  }

  // ─── Streams ───────────────────────────────────────────────────────────────

  /// Playback-state snapshots (position, duration, playing, processing, chunk).
  Stream<LullState> get stateStream =>
      throw UnimplementedError('stateStream has not been implemented.');

  /// Transport commands from system surfaces (lock screen, notification, MPRIS).
  Stream<LullRemoteCommand> get commandStream =>
      throw UnimplementedError('commandStream has not been implemented.');
}
