/// Coarse playback lifecycle, mirrored from the native player.
enum LullProcessingState { idle, loading, buffering, ready, completed }

/// A snapshot of the native player's playback state, delivered on
/// [LullPlayer.stateStream].
class LullState {
  final Duration position;
  final Duration? duration;
  final bool isPlaying;
  final LullProcessingState processingState;

  /// Index of the chunk currently playing within an enqueued sequence
  /// (0 for a single non-queued source).
  final int currentChunkIndex;

  const LullState({
    this.position = Duration.zero,
    this.duration,
    this.isPlaying = false,
    this.processingState = LullProcessingState.idle,
    this.currentChunkIndex = 0,
  });

  static const idle = LullState();

  factory LullState.fromMap(Map<dynamic, dynamic> map) => LullState(
        position: Duration(milliseconds: (map['positionMs'] as num?)?.toInt() ?? 0),
        duration: map['durationMs'] == null
            ? null
            : Duration(milliseconds: (map['durationMs'] as num).toInt()),
        isPlaying: (map['isPlaying'] as bool?) ?? false,
        processingState: LullProcessingState
            .values[(map['processingState'] as num?)?.toInt() ?? 0],
        currentChunkIndex: (map['currentChunkIndex'] as num?)?.toInt() ?? 0,
      );

  LullState copyWith({
    Duration? position,
    Duration? duration,
    bool? isPlaying,
    LullProcessingState? processingState,
    int? currentChunkIndex,
  }) =>
      LullState(
        position: position ?? this.position,
        duration: duration ?? this.duration,
        isPlaying: isPlaying ?? this.isPlaying,
        processingState: processingState ?? this.processingState,
        currentChunkIndex: currentChunkIndex ?? this.currentChunkIndex,
      );
}

/// A transport command originating from a system surface (lock screen,
/// Control Center, media notification, headset/remote, MPRIS).
enum LullCommandType { play, pause, stop, next, previous, seek }

class LullRemoteCommand {
  final LullCommandType type;

  /// Target position for [LullCommandType.seek]; null otherwise.
  final Duration? seekPosition;

  const LullRemoteCommand(this.type, {this.seekPosition});

  factory LullRemoteCommand.fromMap(Map<dynamic, dynamic> map) {
    final type = LullCommandType.values.firstWhere(
      (c) => c.name == map['command'],
      orElse: () => LullCommandType.pause,
    );
    final posMs = (map['positionMs'] as num?)?.toInt();
    return LullRemoteCommand(type,
        seekPosition: posMs == null ? null : Duration(milliseconds: posMs));
  }
}
