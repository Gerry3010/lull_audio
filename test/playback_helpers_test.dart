import 'package:flutter_test/flutter_test.dart';
import 'package:lull_audio/lull_audio.dart';

void main() {
  group('skipTargetIndex', () {
    const chunks = [0, 6, 14, 20];

    test('next jumps to the following chunk start', () {
      expect(skipTargetIndex(chunkStarts: chunks, current: 8, delta: 1, maxIndex: 30), 14);
      expect(skipTargetIndex(chunkStarts: chunks, current: 6, delta: 1, maxIndex: 30), 14);
    });
    test('next past the last chunk clamps to maxIndex', () {
      expect(skipTargetIndex(chunkStarts: chunks, current: 25, delta: 1, maxIndex: 30), 30);
    });
    test('prev mid-chunk restarts the current chunk', () {
      expect(skipTargetIndex(chunkStarts: chunks, current: 18, delta: -1, maxIndex: 30), 14);
    });
    test('prev on a chunk start jumps to the previous start', () {
      expect(skipTargetIndex(chunkStarts: chunks, current: 14, delta: -1, maxIndex: 30), 6);
    });
    test('prev on the first start stays at 0', () {
      expect(skipTargetIndex(chunkStarts: chunks, current: 0, delta: -1, maxIndex: 30), 0);
    });
    test('no chunk starts → single-sentence step, clamped', () {
      expect(skipTargetIndex(chunkStarts: const [], current: 5, delta: 1, maxIndex: 9), 6);
      expect(skipTargetIndex(chunkStarts: const [], current: 9, delta: 1, maxIndex: 9), 9);
    });
  });

  group('conservativeResumeIndex', () {
    test('snaps a mid-chunk position back to the chunk start', () {
      expect(conservativeResumeIndex(12, const [0, 6, 14]), 6);
    });
    test('never returns a position past the last started chunk', () {
      expect(conservativeResumeIndex(99, const [0, 6, 14]), 14);
    });
    test('falls back to the fine index when no chunks recorded', () {
      expect(conservativeResumeIndex(7, const []), 7);
    });
  });

  group('rebasedPlayedMs', () {
    final durations = {0: 1000, 6: 1500, 14: 1200, 20: 900};
    test('sums only chunks before the target', () {
      expect(rebasedPlayedMs(durations, 14), 2500);
      expect(rebasedPlayedMs(durations, 0), 0);
      expect(rebasedPlayedMs(durations, 20), 3700);
    });
    test('a chunk starting exactly at target is excluded', () {
      expect(rebasedPlayedMs({0: 1000, 6: 1500}, 6), 1000);
    });
  });

  group('isWithinDebounceWindow', () {
    final t0 = DateTime(2026, 6, 28, 12);
    test('first tap (null) never debounced', () {
      expect(isWithinDebounceWindow(null, t0), isFalse);
    });
    test('repeat inside window is debounced', () {
      expect(isWithinDebounceWindow(t0, t0.add(const Duration(milliseconds: 120))), isTrue);
    });
    test('after the window passes through; boundary is strict <', () {
      expect(isWithinDebounceWindow(t0, t0.add(const Duration(milliseconds: 350))), isFalse);
      expect(isWithinDebounceWindow(t0, t0.add(const Duration(milliseconds: 300))), isFalse);
    });
  });
}
