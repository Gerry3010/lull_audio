import 'dart:typed_data';

/// An audio source `lull_audio` can play. The bytes/file/url/asset are decoded
/// natively per platform (AVFoundation · Media3/ExoPlayer · GStreamer). Sources
/// can be set as the single current item or enqueued for gapless sequential
/// playback (e.g. a stream of TTS audio chunks).
sealed class LullSource {
  const LullSource();

  /// A local file path.
  const factory LullSource.file(String path) = FileLullSource;

  /// A Flutter asset key (optionally from another [package]).
  const factory LullSource.asset(String assetKey, {String? package}) =
      AssetLullSource;

  /// A remote URL (http/https).
  const factory LullSource.url(Uri uri) = UrlLullSource;

  /// Raw encoded audio bytes (e.g. an MP3 chunk). [mimeType] helps the native
  /// decoder when the container can't be sniffed (default: audio/mpeg).
  factory LullSource.bytes(Uint8List data, {String mimeType}) = BytesLullSource;

  Map<String, dynamic> toMap();
}

class FileLullSource extends LullSource {
  final String path;
  const FileLullSource(this.path);
  @override
  Map<String, dynamic> toMap() => {'kind': 'file', 'path': path};
}

class AssetLullSource extends LullSource {
  final String assetKey;
  final String? package;
  const AssetLullSource(this.assetKey, {this.package});
  @override
  Map<String, dynamic> toMap() =>
      {'kind': 'asset', 'asset': assetKey, if (package != null) 'package': package};
}

class UrlLullSource extends LullSource {
  final Uri uri;
  const UrlLullSource(this.uri);
  @override
  Map<String, dynamic> toMap() => {'kind': 'url', 'url': uri.toString()};
}

class BytesLullSource extends LullSource {
  final Uint8List data;
  final String mimeType;
  BytesLullSource(this.data, {this.mimeType = 'audio/mpeg'});
  @override
  Map<String, dynamic> toMap() =>
      {'kind': 'bytes', 'bytes': data, 'mimeType': mimeType};
}
