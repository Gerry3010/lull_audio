import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lull_audio/lull_audio.dart';
import 'package:lull_audio/lull_audio_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final platform = MethodChannelLullAudio();
  const channel = MethodChannel('lull_audio');
  final invoked = <MethodCall>[];

  setUp(() {
    invoked.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      invoked.add(call);
      if (call.method == 'getPlatformVersion') return '42';
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('getPlatformVersion', () async {
    expect(await platform.getPlatformVersion(), '42');
  });

  test('transport + source calls hit the right method names + args', () async {
    await platform.setSource(const LullSource.file('/a.mp3'));
    await platform.play();
    await platform.seek(const Duration(milliseconds: 1500));

    expect(invoked.map((c) => c.method).toList(),
        ['setSource', 'play', 'seek']);
    expect(invoked.first.arguments, {'kind': 'file', 'path': '/a.mp3'});
    expect(invoked.last.arguments, {'positionMs': 1500});
  });
}
