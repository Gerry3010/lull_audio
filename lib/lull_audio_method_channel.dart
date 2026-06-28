import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'lull_audio_platform_interface.dart';
import 'src/lull_source.dart';
import 'src/lull_state.dart';
import 'src/now_playing_info.dart';

/// Default [LullAudioPlatform] implementation over a [MethodChannel] (commands)
/// plus a single [EventChannel] that multiplexes playback-state and
/// remote-command events (discriminated by a `type` field).
class MethodChannelLullAudio extends LullAudioPlatform {
  @visibleForTesting
  final methodChannel = const MethodChannel('lull_audio');

  @visibleForTesting
  final eventChannel = const EventChannel('lull_audio/events');

  Stream<dynamic>? _events;
  Stream<dynamic> get _broadcast =>
      _events ??= eventChannel.receiveBroadcastStream();

  @override
  Future<String?> getPlatformVersion() =>
      methodChannel.invokeMethod<String>('getPlatformVersion');

  @override
  Future<void> setSource(LullSource source) =>
      methodChannel.invokeMethod('setSource', source.toMap());

  @override
  Future<void> enqueue(LullSource source) =>
      methodChannel.invokeMethod('enqueue', source.toMap());

  @override
  Future<void> clearQueue() => methodChannel.invokeMethod('clearQueue');

  @override
  Future<void> play() => methodChannel.invokeMethod('play');

  @override
  Future<void> pause() => methodChannel.invokeMethod('pause');

  @override
  Future<void> stop() => methodChannel.invokeMethod('stop');

  @override
  Future<void> seek(Duration position) =>
      methodChannel.invokeMethod('seek', {'positionMs': position.inMilliseconds});

  @override
  Future<void> skipToNext() => methodChannel.invokeMethod('skipToNext');

  @override
  Future<void> skipToPrevious() =>
      methodChannel.invokeMethod('skipToPrevious');

  @override
  Future<void> setNowPlaying(NowPlayingInfo info) =>
      methodChannel.invokeMethod('setNowPlaying', info.toMap());

  @override
  Future<void> clearNowPlaying() =>
      methodChannel.invokeMethod('clearNowPlaying');

  @override
  Stream<LullState> get stateStream => _broadcast
      .where((e) => e is Map && e['type'] == 'state')
      .map((e) => LullState.fromMap(e as Map));

  @override
  Stream<LullRemoteCommand> get commandStream => _broadcast
      .where((e) => e is Map && e['type'] == 'command')
      .map((e) => LullRemoteCommand.fromMap(e as Map));
}
