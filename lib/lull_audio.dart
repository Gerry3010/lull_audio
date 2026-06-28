/// lull_audio — play any audio source and show it correctly in the system
/// Now-Playing surfaces (iOS Control Center / lock screen, Android media
/// notification, macOS Now Playing, Linux MPRIS), decoupled from how the audio
/// is produced. Supports gapless sequential byte chunks (e.g. TTS audio).
library;

import 'lull_audio_platform_interface.dart';
import 'src/lull_source.dart';
import 'src/lull_state.dart';
import 'src/now_playing_info.dart';

export 'src/lull_source.dart';
export 'src/lull_state.dart';
export 'src/now_playing_info.dart';
export 'src/playback_helpers.dart';

/// Facade over the active [LullAudioPlatform]. Single player + Now-Playing
/// surface per app (v1). Wire [stateStream] / [commandStream] into your app and
/// feed audio via [setSource] / [enqueue].
class LullPlayer {
  LullAudioPlatform get _platform => LullAudioPlatform.instance;

  /// Platform/OS version string — handy for probing during bring-up.
  Future<String?> platformVersion() => _platform.getPlatformVersion();

  /// Replaces the current item with [source] (resets the chunk queue).
  Future<void> setSource(LullSource source) => _platform.setSource(source);

  /// Appends [source] to the gapless chunk queue (sequential byte chunks).
  Future<void> enqueue(LullSource source) => _platform.enqueue(source);

  /// Clears the queue and stops playback.
  Future<void> clearQueue() => _platform.clearQueue();

  Future<void> play() => _platform.play();
  Future<void> pause() => _platform.pause();
  Future<void> stop() => _platform.stop();
  Future<void> seek(Duration position) => _platform.seek(position);
  Future<void> skipToNext() => _platform.skipToNext();
  Future<void> skipToPrevious() => _platform.skipToPrevious();

  /// Publishes metadata to the system Now-Playing surfaces.
  Future<void> setNowPlaying(NowPlayingInfo info) =>
      _platform.setNowPlaying(info);

  /// Removes the app from the system Now-Playing surfaces.
  Future<void> clearNowPlaying() => _platform.clearNowPlaying();

  /// Playback-state snapshots (position, duration, playing, processing, chunk).
  Stream<LullState> get stateStream => _platform.stateStream;

  /// Transport commands from system surfaces (play/pause/next/prev/stop/seek).
  Stream<LullRemoteCommand> get commandStream => _platform.commandStream;
}
