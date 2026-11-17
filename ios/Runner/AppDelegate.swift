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
final class ClassBridge: NSObject, AVPictureInPictureControllerDelegate {
  static let shared = ClassBridge()

  private var channel: FlutterMethodChannel?
  private let callObserver = CXCallObserver()
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
    for c in callObserver.calls where !c.hasEnded {
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
    if bgTask != .invalid || callObserver.calls.isEmpty {
      soundBack()
    }
  }

  private func soundBack() {
    endBackgroundTime()
    // only when no call is still going on
    let busy = callObserver.calls.contains { !$0.hasEnded }
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
    let key = FlutterDartProject.lookupKey(forAsset: "assets/images/let'sspeak new logo with sir photo.png")
    if let path = Bundle.main.path(forResource: key, ofType: nil) {
      logo.image = UIImage(contentsOfFile: path)
    }

    let live = UILabel()
    live.text = "🔴 LIVE CLASS"
    live.textColor = .white
    live.font = .systemFont(ofSize: 18, weight: .bold)

    let speaking = UILabel()
    speaking.text = "Class is running"
    speaking.textColor = UIColor(red: 0.73, green: 0.83, blue: 0.9, alpha: 1)
    speaking.font = .systemFont(ofSize: 15)
    speaking.numberOfLines = 2

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
