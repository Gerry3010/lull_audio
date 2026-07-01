import AVFoundation
import MediaPlayer

#if os(macOS)
  import AppKit
  import FlutterMacOS
#else
  import Flutter
  import UIKit
#endif

#if os(macOS)
  typealias LullImage = NSImage
#else
  typealias LullImage = UIImage
#endif

/// lull_audio iOS/macOS: native AVFoundation playback (AVQueuePlayer, gapless
/// sequential items incl. byte chunks) wired to MPNowPlayingInfoCenter +
/// MPRemoteCommandCenter for the system Now-Playing surfaces. Shared Darwin
/// source for both platforms (sharedDarwinSource).
public class LullAudioPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private let player = AVQueuePlayer()
  private var eventSink: FlutterEventSink?
  private var timeObserver: Any?
  private var kvoObservations: [NSKeyValueObservation] = []
  private weak var registrar: FlutterPluginRegistrar?

  private var npTitle = ""
  private var npArtist = ""
  private var npArtworkUri: String?
  private var npDurationSec: Double?
  private var artwork: MPMediaItemArtwork?
  private var artworkLoadedForUri: String?

  /// Every item ever inserted since the last setSource/clearQueue, in queue
  /// order. AVQueuePlayer drops items as it advances, so this is the source of
  /// truth for the exact chunk index (identity lookup on currentItem).
  private var queuedItems: [AVPlayerItem] = []
  private var chunkIndex = 0
  private var didComplete = false
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
      NotificationCenter.default.addObserver(
        self, selector: #selector(audioSessionInterrupted),
        name: AVAudioSession.interruptionNotification,
        object: AVAudioSession.sharedInstance())
    #endif
    // Periodic tick keeps the Dart-side position fresh. Now-Playing is NOT
    // refreshed here on purpose: the system extrapolates elapsed time from
    // playbackRate itself; re-setting the info dict every tick makes the
    // lock-screen scrubber jitter and wastes energy.
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
    ) { [weak self] _ in
      self?.emitState()
    }
    kvoObservations.append(
      player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
        DispatchQueue.main.async {
          self?.emitState()
          self?.refreshNowPlaying()
        }
      })
    kvoObservations.append(
      player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
        DispatchQueue.main.async { self?.currentItemChanged() }
      })
    NotificationCenter.default.addObserver(
      self, selector: #selector(itemDidEnd),
      name: .AVPlayerItemDidPlayToEndTime, object: nil)
    setupRemoteCommands()
  }

  private func currentItemChanged() {
    if let current = player.currentItem,
      let idx = queuedItems.firstIndex(where: { $0 === current }) {
      chunkIndex = idx
      didComplete = false
    }
    emitState()
    refreshNowPlaying()
  }

  @objc private func itemDidEnd(_ notification: Notification) {
    // The app may run other AVPlayerItems (e.g. ambient loops); only react to
    // items this plugin queued.
    guard let ended = notification.object as? AVPlayerItem,
      queuedItems.contains(where: { $0 === ended })
    else { return }
    if ended === queuedItems.last {
      didComplete = true
      emitState()
    }
    // Natural advance to a next chunk is picked up by the currentItem KVO.
  }

  #if os(iOS)
    @objc private func audioSessionInterrupted(_ notification: Notification) {
      guard let info = notification.userInfo,
        let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
        let type = AVAudioSession.InterruptionType(rawValue: typeRaw)
      else { return }
      switch type {
      case .began:
        // The system already paused us; sync Dart + lock screen.
        emitState()
        refreshNowPlaying()
      case .ended:
        let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
        if options.contains(.shouldResume) {
          try? AVAudioSession.sharedInstance().setActive(true)
          player.play()
        }
        emitState()
        refreshNowPlaying()
      @unknown default:
        break
      }
    }
  #endif

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
      self?.player.advanceToNextItem(); return .success
    }
    cc.previousTrackCommand.addTarget { [weak self] _ in self?.seekTo(seconds: 0); return .success }
    cc.changePlaybackPositionCommand.addTarget { [weak self] event in
      if let e = event as? MPChangePlaybackPositionCommandEvent { self?.seekTo(seconds: e.positionTime) }
      return .success
    }
  }

  private func seekTo(seconds: Double) {
    player.seek(
      to: CMTime(seconds: seconds, preferredTimescale: 600),
      toleranceBefore: .zero, toleranceAfter: .zero
    ) { [weak self] _ in
      DispatchQueue.main.async {
        self?.emitState()
        self?.refreshNowPlaying()
      }
    }
  }

  // ─── Source → AVPlayerItem ─────────────────────────────────────────────────

  /// AVFoundation infers the container from the file extension (it does not
  /// content-sniff like ExoPlayer/GStreamer), so byte chunks must be written
  /// with a matching extension.
  private func fileExtension(forMimeType mime: String?) -> String {
    switch mime?.lowercased() {
    case "audio/mp4", "audio/aac", "audio/x-m4a", "audio/m4a": return "m4a"
    case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
    case "audio/ogg", "application/ogg", "audio/opus": return "ogg"
    case "audio/flac", "audio/x-flac": return "flac"
    default: return "mp3"  // audio/mpeg and unknown
    }
  }

  private func item(from args: Any?) -> AVPlayerItem? {
    guard let map = args as? [String: Any], let kind = map["kind"] as? String else { return nil }
    var url: URL?
    switch kind {
    case "url": if let s = map["url"] as? String { url = URL(string: s) }
    case "file": if let p = map["path"] as? String { url = URL(fileURLWithPath: p) }
    case "asset":
      if let key = map["asset"] as? String {
        let assetKey: String?
        if let package = map["package"] as? String {
          assetKey = registrar?.lookupKey(forAsset: key, fromPackage: package)
        } else {
          assetKey = registrar?.lookupKey(forAsset: key)
        }
        if let ak = assetKey, let path = Bundle.main.path(forResource: ak, ofType: nil) {
          url = URL(fileURLWithPath: path)
        }
      }
    case "bytes":
      if let data = (map["bytes"] as? FlutterStandardTypedData)?.data {
        let ext = fileExtension(forMimeType: map["mimeType"] as? String)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
          .appendingPathComponent("lull_\(UUID().uuidString).\(ext)")
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
      queuedItems.removeAll()
      chunkIndex = 0
      didComplete = false
      if let it = item(from: call.arguments) {
        queuedItems.append(it)
        player.insert(it, after: nil)
      }
      emitState()
      result(nil)
    case "enqueue":
      if let it = item(from: call.arguments) {
        queuedItems.append(it)
        player.insert(it, after: nil)
        // A late-arriving chunk after the queue drained: Dart decides whether
        // to resume, but the sequence is no longer "completed".
        didComplete = false
      }
      result(nil)
    case "clearQueue":
      player.removeAllItems()
      queuedItems.removeAll()
      chunkIndex = 0
      didComplete = false
      emitState()
      result(nil)
    case "play":
      didComplete = false
      player.play()
      refreshNowPlaying()
      result(nil)
    case "pause":
      player.pause()
      refreshNowPlaying()
      result(nil)
    case "stop":
      player.pause()
      didComplete = false
      seekTo(seconds: 0)
      result(nil)
    case "seek":
      if let ms = (call.arguments as? [String: Any])?["positionMs"] as? Int {
        seekTo(seconds: Double(ms) / 1000.0)
      }
      result(nil)
    case "skipToNext":
      player.advanceToNextItem()
      result(nil)
    case "skipToPrevious":
      seekTo(seconds: 0)
      result(nil)
    case "setNowPlaying":
      let m = call.arguments as? [String: Any]
      npTitle = (m?["title"] as? String) ?? ""
      npArtist = (m?["artist"] as? String) ?? ""
      npDurationSec = nil
      if let d = m?["durationMs"] as? Int { npDurationSec = Double(d) / 1000.0 }
      let uri = m?["artworkUri"] as? String
      if uri != npArtworkUri {
        npArtworkUri = uri
        artwork = nil
        artworkLoadedForUri = nil
        loadArtworkIfNeeded()
      }
      refreshNowPlaying()
      result(nil)
    case "clearNowPlaying":
      npTitle = ""
      npArtist = ""
      npArtworkUri = nil
      npDurationSec = nil
      artwork = nil
      artworkLoadedForUri = nil
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
      "positionMs": Int((pos.isFinite && pos > 0 ? pos : 0) * 1000),
      "isPlaying": isPlaying,
      "processingState": processingState(),
      "currentChunkIndex": chunkIndex,
    ]
    let dur = CMTimeGetSeconds(durRaw)
    if dur.isFinite && dur > 0 { map["durationMs"] = Int(dur * 1000) }
    sink(map)
  }

  private func processingState() -> Int {
    if didComplete { return 4 }  // completed
    switch player.currentItem?.status {
    case .readyToPlay: return 3  // ready
    case .failed: return 0
    default:
      return player.currentItem == nil ? 0 : 2  // idle / buffering
    }
  }

  private func loadArtworkIfNeeded() {
    guard let uri = npArtworkUri, artworkLoadedForUri != uri else { return }
    artworkLoadedForUri = uri
    let apply: (LullImage?) -> Void = { [weak self] image in
      DispatchQueue.main.async {
        guard let self = self, self.npArtworkUri == uri, let image = image else { return }
        self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        self.refreshNowPlaying()
      }
    }
    if uri.hasPrefix("http://") || uri.hasPrefix("https://") {
      guard let url = URL(string: uri) else { return }
      URLSession.shared.dataTask(with: url) { data, _, _ in
        apply(data.flatMap { LullImage(data: $0) })
      }.resume()
    } else {
      let path = uri.hasPrefix("file://") ? (URL(string: uri)?.path ?? uri) : uri
      DispatchQueue.global(qos: .utility).async {
        let data = FileManager.default.contents(atPath: path)
        apply(data.flatMap { LullImage(data: $0) })
      }
    }
  }

  private func refreshNowPlaying() {
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: npTitle,
      MPMediaItemPropertyArtist: npArtist,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: max(
        0, CMTimeGetSeconds(player.currentTime())),
      MPNowPlayingInfoPropertyPlaybackRate: Double(player.rate),
    ]
    if let d = npDurationSec {
      info[MPMediaItemPropertyPlaybackDuration] = d
    } else if let itemDur = player.currentItem?.duration {
      let s = CMTimeGetSeconds(itemDur)
      if s.isFinite && s > 0 { info[MPMediaItemPropertyPlaybackDuration] = s }
    }
    if let artwork = artwork { info[MPMediaItemPropertyArtwork] = artwork }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
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
    kvoObservations.forEach { $0.invalidate() }
    NotificationCenter.default.removeObserver(self)
    tempFiles.forEach { try? FileManager.default.removeItem(at: $0) }
  }
}
