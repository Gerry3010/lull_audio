## 0.0.1 — Phase 0 (scaffold)

* Dart API + cross-platform channel contract: `LullPlayer`, `LullSource`
  (file/asset/url/bytes), `NowPlayingInfo`, `LullState`, `LullRemoteCommand`.
* Method channel `lull_audio` (commands) + event channel `lull_audio/events`
  (state + remote commands).
* Player-agnostic skip/resume/debounce helpers (`skipTargetIndex`,
  `conservativeResumeIndex`, `rebasedPlayedMs`, `isWithinDebounceWindow`).
* Native implementations are stubs — landing per platform next (iOS first).
