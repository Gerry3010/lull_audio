import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lull_audio/lull_audio.dart';

void main() => runApp(const MyApp());

class MyApp extends StatefulWidget {
  const MyApp({super.key});
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final _player = LullPlayer();
  String _platformVersion = 'Unknown';
  LullState _state = LullState.idle;
  StreamSubscription<LullState>? _stateSub;
  StreamSubscription<LullRemoteCommand>? _cmdSub;

  @override
  void initState() {
    super.initState();
    _player.platformVersion().then((v) {
      if (mounted) setState(() => _platformVersion = v ?? 'Unknown');
    });
    // System transport commands (lock screen / notification / MPRIS) drive us.
    _cmdSub = _player.commandStream.listen((c) {
      switch (c.type) {
        case LullCommandType.play:
          _player.play();
        case LullCommandType.pause:
          _player.pause();
        case LullCommandType.stop:
          _player.stop();
        case LullCommandType.next:
          _player.skipToNext();
        case LullCommandType.previous:
          _player.skipToPrevious();
        case LullCommandType.seek:
          if (c.seekPosition != null) _player.seek(c.seekPosition!);
      }
    });
    _stateSub = _player.stateStream.listen((s) {
      if (mounted) setState(() => _state = s);
    });
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _cmdSub?.cancel();
    super.dispose();
  }

  Future<void> _demo() async {
    await _player.setSource(LullSource.url(Uri.parse(
        'https://flutter.github.io/assets-for-api-docs/assets/audio/rooster.mp3')));
    await _player.setNowPlaying(const NowPlayingInfo(
      title: 'lull_audio demo',
      artist: 'Rooster',
      duration: Duration(seconds: 2),
    ));
    await _player.play();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('lull_audio example')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('Platform: $_platformVersion'),
              const SizedBox(height: 8),
              Text('playing=${_state.isPlaying} '
                  'pos=${_state.position.inSeconds}s '
                  'state=${_state.processingState.name}'),
              const SizedBox(height: 24),
              Wrap(spacing: 12, children: [
                ElevatedButton(onPressed: _demo, child: const Text('Load + Play')),
                ElevatedButton(onPressed: _player.pause, child: const Text('Pause')),
                ElevatedButton(onPressed: _player.stop, child: const Text('Stop')),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
