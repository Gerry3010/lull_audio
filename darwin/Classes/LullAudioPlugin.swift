import AVFoundation
import MediaPlayer

#if os(macOS)
  import FlutterMacOS
#else
  import Flutter
  import UIKit
#endif

/// lull_audio iOS/macOS: native AVFoundation playback (AVQueuePlayer, gapless
/// sequential items incl. byte chunks) wired to MPNowPlayingInfoCenter +
/// MPRemoteCommandCenter for the system Now-Playing surfaces. Shared Darwin
/// source for both platforms (sharedDarwinSource).
public class LullAudioPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private let player = AVQueuePlayer()
  private var eventSink: FlutterEventSink?
  private var timeObserver: Any?
  private weak var registrar: FlutterPluginRegistrar?

  private var npTitle = ""
  private var npArtist = ""
  private var npArtworkUri: String?
  private var npDurationSec: Double?
  private var chunkIndex = 0
  private var tempFiles: [URL] = []

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(macOS)
      let messenger = registrar.messenger
    #else
      let messenger = registrar.messenger()
    #endif
    let channel = FlutterMethodChannel(name: "lull_audio", binaryMessenger: messenger)
    let events = FlutterEventChannel(name: "lull_audio/events", binaryMessenger: messenger)
    let instance = LullAudioPlugin()
    instance.registrar = registrar
    registrar.addMethodCallDelegate(instance, channel: channel)
    events.setStreamHandler(instance)
    instance.setup()
  }

  private func setup() {
    player.actionAtItemEnd = .advance
    #if os(iOS)
      try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
      try? AVAudioSession.sharedInstance().setActive(true)
    #endif
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
    ) { [weak self] _ in
      self?.emitState()
      self?.refreshNowPlaying()
    }
    player.addObserver(self, forKeyPath: "timeControlStatus", options: [.new], context: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(itemDidEnd),
      name: .AVPlayerItemDidPlayToEndTime, object: nil)
    setupRemoteCommands()
  }

  @objc private func itemDidEnd() {
    // Natural advance to the next queued chunk.
    if player.items().count > 1 { chunkIndex += 1 }
    emitState()
  }

  // ─── Remote commands (drive the player directly) ───────────────────────────

  private func setupRemoteCommands() {
    let cc = MPRemoteCommandCenter.shared()
    cc.playCommand.addTarget { [weak self] _ in self?.player.play(); self?.refreshNowPlaying(); return .success }
    cc.pauseCommand.addTarget { [weak self] _ in self?.player.pause(); self?.refreshNowPlaying(); return .success }
    cc.togglePlayPauseCommand.addTarget { [weak self] _ in
      guard let self = self else { return .commandFailed }
      if self.player.timeControlStatus == .paused { self.player.play() } else { self.player.pause() }
      self.refreshNowPlaying()
      return .success
    }
    cc.nextTrackCommand.addTarget { [weak self] _ in
      self?.player.advanceToNextItem(); self?.chunkIndex += 1; return .success
    }
    cc.previousTrackCommand.addTarget { [weak self] _ in self?.seekTo(seconds: 0); return .success }
    cc.changePlaybackPositionCommand.addTarget { [weak self] event in
      if let e = event as? MPChangePlaybackPositionCommandEvent { self?.seekTo(seconds: e.positionTime) }
      return .success
    }
  }

  private func seekTo(seconds: Double) {
    player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
  }

  // ─── Source → AVPlayerItem ─────────────────────────────────────────────────

  private func item(from args: Any?) -> AVPlayerItem? {
    guard let map = args as? [String: Any], let kind = map["kind"] as? String else { return nil }
    var url: URL?
    switch kind {
    case "url": if let s = map["url"] as? String { url = URL(string: s) }
    case "file": if let p = map["path"] as? String { url = URL(fileURLWithPath: p) }
    case "asset":
      if let key = map["asset"] as? String, let ak = registrar?.lookupKey(forAsset: key),
        let path = Bundle.main.path(forResource: ak, ofType: nil) {
        url = URL(fileURLWithPath: path)
      }
    case "bytes":
      if let data = (map["bytes"] as? FlutterStandardTypedData)?.data {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
          .appendingPathComponent("lull_\(UUID().uuidString).bin")
        try? data.write(to: tmp)
        tempFiles.append(tmp)
        url = tmp
      }
    default: break
    }
    guard let u = url else { return nil }
    return AVPlayerItem(url: u)
  }

  // ─── Method channel ────────────────────────────────────────────────────────

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformVersion":
      #if os(macOS)
        result("macOS " + ProcessInfo.processInfo.operatingSystemVersionString)
      #else
        result("iOS " + UIDevice.current.systemVersion)
      #endif
    case "setSource":
      player.removeAllItems()
      chunkIndex = 0
      if let it = item(from: call.arguments) { player.insert(it, after: nil) }
      result(nil)
    case "enqueue":
      if let it = item(from: call.arguments) { player.insert(it, after: nil) }
      result(nil)
    case "clearQueue":
      player.removeAllItems(); chunkIndex = 0; result(nil)
    case "play":
      player.play(); refreshNowPlaying(); result(nil)
    case "pause":
      player.pause(); refreshNowPlaying(); result(nil)
    case "stop":
      player.pause(); seekTo(seconds: 0); refreshNowPlaying(); result(nil)
    case "seek":
      if let ms = (call.arguments as? [String: Any])?["positionMs"] as? Int {
        seekTo(seconds: Double(ms) / 1000.0)
      }
      result(nil)
    case "skipToNext":
      player.advanceToNextItem(); chunkIndex += 1; result(nil)
    case "skipToPrevious":
      seekTo(seconds: 0); result(nil)
    case "setNowPlaying":
      let m = call.arguments as? [String: Any]
      npTitle = (m?["title"] as? String) ?? ""
      npArtist = (m?["artist"] as? String) ?? ""
      npArtworkUri = m?["artworkUri"] as? String
      if let d = m?["durationMs"] as? Int { npDurationSec = Double(d) / 1000.0 }
      refreshNowPlaying()
      result(nil)
    case "clearNowPlaying":
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // ─── State + Now-Playing ───────────────────────────────────────────────────

  private func emitState() {
    guard let sink = eventSink else { return }
    let pos = CMTimeGetSeconds(player.currentTime())
    let durRaw = player.currentItem?.duration ?? CMTime.indefinite
    let isPlaying = player.timeControlStatus == .playing
    var map: [String: Any] = [
      "type": "state",
      "positionMs": Int((pos.isFinite ? pos : 0) * 1000),
      "isPlaying": isPlaying,
      "processingState": processingState(),
      "currentChunkIndex": chunkIndex,
    ]
    let dur = CMTimeGetSeconds(durRaw)
    if dur.isFinite && dur > 0 { map["durationMs"] = Int(dur * 1000) }
    sink(map)
  }

  private func processingState() -> Int {
    switch player.currentItem?.status {
    case .readyToPlay: return 3  // ready
    case .failed: return 0
    default:
      return player.currentItem == nil ? 0 : 2  // idle / buffering
    }
  }

  private func refreshNowPlaying() {
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: npTitle,
      MPMediaItemPropertyArtist: npArtist,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: CMTimeGetSeconds(player.currentTime()),
      MPNowPlayingInfoPropertyPlaybackRate: Double(player.rate),
    ]
    if let d = npDurationSec { info[MPMediaItemPropertyPlaybackDuration] = d }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  public override func observeValue(
    forKeyPath keyPath: String?, of object: Any?,
    change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?
  ) {
    if keyPath == "timeControlStatus" {
      emitState()
      refreshNowPlaying()
    }
  }

  // ─── FlutterStreamHandler ──────────────────────────────────────────────────

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError? {
    eventSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  deinit {
    if let t = timeObserver { player.removeTimeObserver(t) }
    player.removeObserver(self, forKeyPath: "timeControlStatus")
    NotificationCenter.default.removeObserver(self)
    tempFiles.forEach { try? FileManager.default.removeItem(at: $0) }
  }
}
