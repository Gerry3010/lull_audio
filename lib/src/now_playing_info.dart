import 'dart:typed_data';

/// Metadata shown in the system Now-Playing surfaces (iOS Control Center /
/// lock screen, Android media notification, macOS Now Playing, Linux MPRIS).
/// Decoupled from how the audio is produced — set it whenever your metadata
/// changes; position is synced separately via the player's playback state.
class NowPlayingInfo {
  final String title;
  final String? artist;
  final String? album;

  /// Artwork as raw image bytes (PNG/JPEG). Takes precedence over [artworkUri].
  final Uint8List? artworkBytes;

  /// Artwork as a file/asset/remote URI (used when [artworkBytes] is null).
  final Uri? artworkUri;

  /// Total duration of the current item, if known.
  final Duration? duration;

  const NowPlayingInfo({
    required this.title,
    this.artist,
    this.album,
    this.artworkBytes,
    this.artworkUri,
    this.duration,
  });

  Map<String, dynamic> toMap() => {
        'title': title,
        if (artist != null) 'artist': artist,
        if (album != null) 'album': album,
        if (artworkBytes != null) 'artworkBytes': artworkBytes,
        if (artworkUri != null) 'artworkUri': artworkUri.toString(),
        if (duration != null) 'durationMs': duration!.inMilliseconds,
      };
}
