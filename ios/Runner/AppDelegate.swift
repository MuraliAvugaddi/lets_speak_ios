import AVFoundation
import AVKit
import CallKit
import Flutter
import UIKit
import UserNotifications
import flutter_local_notifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {

    // ⏰ Class reminders: lets scheduled notifications work in the background
    FlutterLocalNotificationsPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }

    // ⏰ Class reminders: show the reminder even while the app is open on screen
    UNUserNotificationCenter.current().delegate = self as UNUserNotificationCenterDelegate

    return super.application(
      application,
      didFinishLaunchingWithOptions: launchOptions
    )
  }

  func didInitializeImplicitFlutterEngine(
    _ engineBridge: FlutterImplicitEngineBridge
  ) {
    GeneratedPluginRegistrant.register(
      with: engineBridge.pluginRegistry
    )
    // 🎧 live class: phone calls + small window (same channel name as Android)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LetsSpeakClass") {
      ClassBridge.shared.attach(messenger: registrar.messenger())
    }
  }
}

// =============================================================================
// 🎧 LIVE CLASS on iPhone
//  📞 Phone / WhatsApp call: tells Flutter when a call is ANSWERED (class pauses,
//     mic off) and when it ends (class sound + mic come back by themselves).
//     iPhone itself stops all app sound while a call RINGS (Apple rule).
//  ⏳ Keeps the class connection alive ~30 s while a call is ringing / starting,
//     so a short call doesn't drop the class.
//  📺 Small window: in class → student opens WhatsApp / home → the class shows
//     as a small floating window (iOS 15+). Tap it → back to the class.
// =============================================================================
final class ClassBridge: NSObject, AVPictureInPictureControllerDelegate, CXProviderDelegate,
  CXCallObserverDelegate
{
  static let shared = ClassBridge()

  // 📞 the class itself as an iPhone call (CallKit) → a ringing phone does NOT
  //    silence the class; answered → class on hold; call over → class back
  private lazy var provider: CXProvider = {
    let cfg = CXProviderConfiguration()
    cfg.supportsVideo = false
    cfg.maximumCallGroups = 1
    cfg.maximumCallsPerCallGroup = 1
    cfg.supportedHandleTypes = [.generic]
    cfg.includesCallsInRecents = false  // the class doesn't show in the Phone app
    let p = CXProvider(configuration: cfg)
    p.setDelegate(self, queue: nil)
    return p
  }()
  private let callController = CXCallController()
  private var classCallId: UUID?
  private var classTitle = "Let's Speak • Live class"
  private var classWanted = false
  private var classHeld = false

  private var channel: FlutterMethodChannel?
  private let phoneCalls = CXCallObserver()
  private var bgTask: UIBackgroundTaskIdentifier = .invalid

  // small window
  private var pipController: AnyObject?  // AVPictureInPictureController (iOS 15+)
  private var sourceView: UIView?
  private var speakingLabel: UILabel?
  private var micLabel: UILabel?
  private var wantPip = false

  func attach(messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: "letsspeak/class_service", binaryMessenger: messenger)
    channel = ch
    ch.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      switch call.method {
      case "callState":
        result(self.callState())
      case "classCall":
        let args = call.arguments as? [String: Any] ?? [:]
        let on = args["on"] as? Bool ?? false
        if let t = args["title"] as? String, !t.isEmpty { self.classTitle = t }
        DispatchQueue.main.async {
          if on { self.startClassCall(result) } else {
            self.endClassCall()
            result(true)
          }
        }
      case "pip":
        let on = (call.arguments as? [String: Any])?["on"] as? Bool ?? false
        DispatchQueue.main.async {
          self.wantPip = on
          if on { self.startPip() } else { self.stopPip() }
        }
        result(true)
      case "pipInfo":
        let info = call.arguments as? [String: Any] ?? [:]
        DispatchQueue.main.async { self.updatePip(info) }
        result(true)
      case "outputs":
        result([])
      case "start", "stop", "restoreMode":
        result(true)  // Android-only things
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    phoneCalls.setDelegate(self, queue: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(onInterruption(_:)),
      name: AVAudioSession.interruptionNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(onBecameActive),
      name: UIApplication.didBecomeActiveNotification, object: nil)
  }

  // ---------------------------------------------------------------------------
  // 📞 calls
  // ---------------------------------------------------------------------------
  private func callState() -> [String: Any] {
    var answered = false
    var ringing = false
    // other calls only (the class itself is also a "call" now)
    for c in phoneCalls.calls where !c.hasEnded && c.uuid != classCallId {
      if c.hasConnected || c.isOutgoing {
        answered = true
      } else {
        ringing = true
      }
    }
    // mode: 1 ringing, 2 in a call, 3 class (never 0 → no Android "restore" on iPhone)
    return ["phoneCall": answered, "voipCall": false, "mode": answered ? 2 : (ringing ? 1 : 3)]
  }

  @objc private func onInterruption(_ note: Notification) {
    guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: raw)
    else { return }
    if type == .began {
      // call ringing / Siri / alarm → iPhone stops our sound. Keep the class
      // connection alive for a while so we don't "lose internet".
      beginBackgroundTime()
    } else {
      soundBack()
    }
  }

  @objc private func onBecameActive() {
    // back in the app after a call → make sure the class sound is on again
    soundBack()  // (does nothing while another call is still going on)
  }

  private func soundBack() {
    endBackgroundTime()
    // only when no call is still going on
    let busy = phoneCalls.calls.contains { !$0.hasEnded && $0.uuid != classCallId }
    if busy { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
      self?.channel?.invokeMethod("soundBack", arguments: nil)
    }
  }

  private func beginBackgroundTime() {
    guard bgTask == .invalid else { return }
    bgTask = UIApplication.shared.beginBackgroundTask(withName: "letsspeak.class") { [weak self] in
      self?.endBackgroundTime()
    }
  }

  private func endBackgroundTime() {
    guard bgTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(bgTask)
    bgTask = .invalid
  }

  // ---------------------------------------------------------------------------
  // 📞 the class as an iPhone call (CallKit)
  // ---------------------------------------------------------------------------
  private func send(_ method: String, _ value: Any?) {
    DispatchQueue.main.async { [weak self] in
      self?.channel?.invokeMethod(method, arguments: value)
    }
  }

  private func startClassCall(_ result: @escaping FlutterResult) {
    classWanted = true
    if classCallId != nil {
      result(true)
      return
    }
    _ = provider  // make sure iOS knows our call handler before asking
    let id = UUID()
    let handle = CXHandle(type: .generic, value: classTitle)
    let start = CXStartCallAction(call: id, handle: handle)
    start.isVideo = false
    callController.request(CXTransaction(action: start)) { [weak self] error in
      DispatchQueue.main.async {
        guard let self = self else {
          result(false)
          return
        }
        if let error = error {
          print("[LetsSpeak] class call could not start: \(error)")
          result(false)
          return
        }
        self.classCallId = id
        self.classHeld = false
        self.provider.reportOutgoingCall(with: id, startedConnectingAt: Date())
        self.provider.reportOutgoingCall(with: id, connectedAt: Date())
        let update = CXCallUpdate()
        update.remoteHandle = handle
        update.localizedCallerName = self.classTitle
        update.hasVideo = false
        update.supportsHolding = true
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        self.provider.reportCall(with: id, updated: update)
        result(true)
      }
    }
  }

  private func endClassCall() {
    classWanted = false
    guard let id = classCallId else { return }
    callController.request(CXTransaction(action: CXEndCallAction(call: id))) { error in
      if let error = error { print("[LetsSpeak] class call end: \(error)") }
    }
  }

  /// other call finished → bring the class back (un-hold, or start it again)
  private func resumeClassCall() {
    guard classWanted else { return }
    if phoneCalls.calls.contains(where: { !$0.hasEnded && $0.uuid != classCallId }) { return }
    if let id = classCallId {
      if classHeld {
        callController.request(CXTransaction(action: CXSetHeldCallAction(call: id, onHold: false))) {
          error in
          if let error = error { print("[LetsSpeak] class un-hold: \(error)") }
        }
      }
    } else {
      startClassCall { _ in }
    }
  }

  // CXCallObserverDelegate: any call started / answered / ended
  func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
    guard classWanted, call.uuid != classCallId, call.hasEnded else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
      self?.resumeClassCall()
    }
  }

  // CXProviderDelegate
  func providerDidReset(_ provider: CXProvider) {
    classCallId = nil
    classHeld = false
    send("audioActive", false)
  }

  func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    if action.callUUID == classCallId {
      // ended by us (leave) or by iPhone ("End & Accept") → class waits for the call to finish
      classCallId = nil
      classHeld = false
    }
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
    if action.callUUID == classCallId { classHeld = action.isOnHold }
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    action.fulfill()
    if action.callUUID == classCallId { send("setMuted", action.isMuted) }
  }

  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    send("audioActive", true)  // iOS gave the sound to the class
  }

  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    send("audioActive", false)  // another call took the sound (class on hold)
  }

  // ---------------------------------------------------------------------------
  // 📺 small window (Picture in Picture for calls, iOS 15+)
  // ---------------------------------------------------------------------------
  private static func rootView() -> UIView? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
    let window = windows.first { $0.isKeyWindow } ?? windows.first
    return window?.rootViewController?.view
  }

  private func startPip() {
    guard #available(iOS 15.0, *) else { return }
    guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
    if pipController != nil { return }
    guard let root = Self.rootView() else {
      // Flutter view not ready yet → try again shortly
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
        if self?.wantPip == true { self?.startPip() }
      }
      return
    }

    // tiny invisible "source" view (iOS needs one on screen to start from)
    let src = UIView(frame: CGRect(x: 0, y: max(0, root.bounds.height - 2), width: 2, height: 2))
    src.backgroundColor = .clear
    src.isUserInteractionEnabled = false
    src.autoresizingMask = [.flexibleTopMargin, .flexibleRightMargin]
    root.addSubview(src)

    let content = AVPictureInPictureVideoCallViewController()
    content.preferredContentSize = CGSize(width: 300, height: 200)
    buildCard(in: content.view)

    let source = AVPictureInPictureController.ContentSource(
      activeVideoCallSourceView: src, contentViewController: content)
    let pip = AVPictureInPictureController(contentSource: source)
    pip.canStartPictureInPictureAutomaticallyFromInline = true  // leave the app → small window
    pip.delegate = self

    pipController = pip
    sourceView = src
  }

  private func stopPip() {
    guard #available(iOS 15.0, *) else { return }
    if let pip = pipController as? AVPictureInPictureController {
      pip.canStartPictureInPictureAutomaticallyFromInline = false
      if pip.isPictureInPictureActive { pip.stopPictureInPicture() }
    }
    pipController = nil
    sourceView?.removeFromSuperview()
    sourceView = nil
  }

  private func buildCard(in view: UIView) {
    view.backgroundColor = UIColor(red: 14 / 255, green: 47 / 255, blue: 72 / 255, alpha: 1)

    let logo = UIImageView()
    logo.contentMode = .scaleAspectFill
    logo.clipsToBounds = true
    logo.layer.cornerRadius = 30
    logo.layer.borderWidth = 2
    logo.layer.borderColor = UIColor(red: 0, green: 0.62, blue: 0.62, alpha: 1).cgColor
    // Sir logo (ios/Runner/Assets.xcassets/ClassLogo), else the same picture from Flutter
    if let img = UIImage(named: "ClassLogo") {
      logo.image = img
    } else {
      let key = FlutterDartProject.lookupKey(forAsset: "assets/images/let'sspeak new logo with sir photo.png")
      let path = Bundle.main.bundlePath + "/Frameworks/App.framework/" + key
      logo.image = UIImage(contentsOfFile: path)
        ?? Bundle.main.path(forResource: key, ofType: nil).flatMap { UIImage(contentsOfFile: $0) }
    }

    let live = UILabel()
    live.text = "🔴 LIVE"
    live.textColor = .white
    live.font = .systemFont(ofSize: 20, weight: .bold)
    live.adjustsFontSizeToFitWidth = true
    live.minimumScaleFactor = 0.6

    let speaking = UILabel()
    speaking.text = "Class is running"
    speaking.textColor = UIColor(red: 0.73, green: 0.83, blue: 0.9, alpha: 1)
    speaking.font = .systemFont(ofSize: 15)
    speaking.numberOfLines = 2
    speaking.adjustsFontSizeToFitWidth = true
    speaking.minimumScaleFactor = 0.7

    let mic = UILabel()
    mic.text = "🔇 Muted"
    mic.textColor = .white
    mic.font = .systemFont(ofSize: 14, weight: .semibold)

    let hint = UILabel()
    hint.text = "Tap to open"
    hint.textColor = UIColor(red: 0.56, green: 0.69, blue: 0.78, alpha: 1)
    hint.font = .systemFont(ofSize: 13)

    let texts = UIStackView(arrangedSubviews: [live, speaking])
    texts.axis = .vertical
    texts.spacing = 4
    let top = UIStackView(arrangedSubviews: [logo, texts])
    top.axis = .horizontal
    top.spacing = 14
    top.alignment = .center
    let bottom = UIStackView(arrangedSubviews: [mic, UIView(), hint])
    bottom.axis = .horizontal
    let all = UIStackView(arrangedSubviews: [top, bottom])
    all.axis = .vertical
    all.spacing = 16
    all.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(all)
    NSLayoutConstraint.activate([
      logo.widthAnchor.constraint(equalToConstant: 60),
      logo.heightAnchor.constraint(equalToConstant: 60),
      all.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      all.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      all.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])

    speakingLabel = speaking
    micLabel = mic
  }

  private func updatePip(_ info: [String: Any]) {
    let onCall = info["onCall"] as? Bool ?? false
    let who = info["speaking"] as? String ?? ""
    let mic = info["mic"] as? Bool ?? false
    speakingLabel?.text = onCall ? "Paused — you are on a call" : (who.isEmpty ? "Class is running" : "\(who) is speaking")
    micLabel?.text = mic ? "🎙 Mic on" : "🔇 Muted"
  }

  // tap the small window → back to the class screen
  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    completionHandler(true)
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    print("[LetsSpeak] small window could not start: \(error)")
  }
}
