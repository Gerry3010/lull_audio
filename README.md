# lull_audio

Play any audio source — files, assets, URLs, raw byte chunks — and show it
correctly in the **system Now-Playing surfaces** across **iOS, Android, macOS
and Linux**, decoupled from *how* the audio is produced.

Built because `audio_service` renders nothing on iOS when the audio comes from
separate player/TTS instances. `lull_audio` drives the native Now-Playing
centers directly and ships its own native playback, so lock-screen / Control
Center / media-notification / MPRIS controls and metadata always work — even
for **gapless sequential byte chunks** (e.g. streamed TTS audio).

> **Status: early development.** Dart API + cross-platform contract are in place
> (Phase 0). Native implementations land per platform: iOS → Android → macOS →
> Linux.

## What it does
- **Sources:** `LullSource.file/.asset/.url/.bytes`.
- **Gapless chunk queue:** `enqueue(...)` for sequential byte chunks.
- **Transport:** play / pause / stop / seek / next / previous.
- **Now-Playing:** title, artist, album, artwork, duration + live position.
- **System commands:** lock screen / notification / headset / MPRIS → `commandStream`.

## Native stack (from scratch, per platform)
| Platform | Playback | Now-Playing |
|----------|----------|-------------|
| iOS / macOS | AVFoundation | MPNowPlayingInfoCenter + MPRemoteCommandCenter |
| Android | Media3 / ExoPlayer | MediaSession + media notification |
| Linux | GStreamer | MPRIS (D-Bus) |

## Usage
```dart
final player = LullPlayer();

player.commandStream.listen((c) {
  switch (c.type) {
    case LullCommandType.play: player.play();
    case LullCommandType.pause: player.pause();
    // … next / previous / stop / seek
    default: break;
  }
});

await player.setSource(LullSource.url(Uri.parse('https://…/track.mp3')));
await player.setNowPlaying(const NowPlayingInfo(title: 'My Track', artist: 'Me'));
await player.play();

// Gapless byte chunks (e.g. TTS):
for (final chunk in chunks) {
  await player.enqueue(LullSource.bytes(chunk));
}
```

## License
MIT © 2026 Gerald Hofbauer
