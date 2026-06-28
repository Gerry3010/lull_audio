// Pure, player-agnostic helpers for chunk navigation and resume positions.
// Free of Flutter/native dependencies so they can be unit tested directly.

/// The conservative resume position for [fineIndex]: the start of the chunk that
/// is actually playing. A time-estimated fine index can run ahead of the real
/// audio, so persisting it directly makes resume overshoot. [chunkStarts] are
/// the chunk-start indices that have actually begun playing.
int conservativeResumeIndex(int fineIndex, List<int> chunkStarts) {
  if (chunkStarts.isEmpty) return fineIndex;
  return chunkStarts.lastWhere((i) => i <= fineIndex, orElse: () => 0);
}

/// Target chunk index for a prev/next skip. [chunkStarts] are the indices where
/// chunks began; [delta] is +1 (next) or -1 (prev). Next jumps to the following
/// chunk start; prev restarts the current chunk (or jumps to the previous start
/// when already on one). With no chunk starts it falls back to a single step.
/// Clamped to [0, maxIndex].
int skipTargetIndex({
  required List<int> chunkStarts,
  required int current,
  required int delta,
  required int maxIndex,
}) {
  int newIndex;
  if (chunkStarts.isNotEmpty) {
    if (delta > 0) {
      newIndex =
          chunkStarts.firstWhere((i) => i > current, orElse: () => maxIndex);
    } else {
      final currentChunkStart =
          chunkStarts.lastWhere((i) => i <= current, orElse: () => 0);
      if (currentChunkStart < current) {
        newIndex = currentChunkStart;
      } else {
        newIndex =
            chunkStarts.lastWhere((i) => i < currentChunkStart, orElse: () => 0);
      }
    }
  } else {
    newIndex = current + delta;
  }
  return newIndex.clamp(0, maxIndex < 0 ? 0 : maxIndex);
}

/// Rebased played-ms offset after a jump to [target]: the summed measured
/// durations of the chunks that start *before* [target]. Keeps a resume point
/// correct after a backward (or forward) jump.
int rebasedPlayedMs(Map<int, int> chunkDurationMs, int target) {
  int ms = 0;
  chunkDurationMs.forEach((start, dur) {
    if (start < target) ms += dur;
  });
  return ms;
}

/// Whether [now] is within [window] of [last] — debounces rapid repeated
/// transport taps that otherwise race the playback state machine. [last] null ⇒
/// first tap, never debounced.
bool isWithinDebounceWindow(DateTime? last, DateTime now,
    {Duration window = const Duration(milliseconds: 300)}) {
  if (last == null) return false;
  return now.difference(last) < window;
}
