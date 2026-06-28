import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lull_audio/lull_audio.dart';
import 'package:lull_audio/lull_audio_platform_interface.dart';
import 'package:lull_audio/lull_audio_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Records which platform calls the facade forwards. Inherits the throwing
/// defaults from [LullAudioPlatform] and overrides only what the tests touch.
class MockLullAudioPlatform extends LullAudioPlatform
    with MockPlatformInterfaceMixin {
  final calls = <String>[];

  @override
  Future<String?> getPlatformVersion() async => '42';
  @override
  Future<void> setSource(LullSource source) async =>
      calls.add('setSource:${source.toMap()['kind']}');
  @override
  Future<void> enqueue(LullSource source) async =>
      calls.add('enqueue:${source.toMap()['kind']}');
  @override
  Future<void> play() async => calls.add('play');
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> seek(Duration position) async =>
      calls.add('seek:${position.inMilliseconds}');
  @override
  Future<void> setNowPlaying(NowPlayingInfo info) async =>
      calls.add('nowPlaying:${info.title}');
}

void main() {
  test('MethodChannelLullAudio is the default instance', () {
    expect(LullAudioPlatform.instance, isInstanceOf<MethodChannelLullAudio>());
  });

  test('LullPlayer forwards calls to the active platform', () async {
    final mock = MockLullAudioPlatform();
    LullAudioPlatform.instance = mock;
    final player = LullPlayer();

    expect(await player.platformVersion(), '42');
    await player.setSource(const LullSource.file('/a.mp3'));
    await player.enqueue(LullSource.bytes(Uint8List.fromList([1, 2, 3])));
    await player.play();
    await player.seek(const Duration(seconds: 3));
    await player.pause();
    await player.setNowPlaying(const NowPlayingInfo(title: 'Story'));

    expect(mock.calls, [
      'setSource:file',
      'enqueue:bytes',
      'play',
      'seek:3000',
      'pause',
      'nowPlaying:Story',
    ]);
  });
}
