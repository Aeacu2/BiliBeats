import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    excludeDownloadsFromBackup()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }

  /// Downloaded audio and cached covers can be fetched again; they do not
  /// belong in an iCloud or computer backup (Android excludes all app data).
  private func excludeDownloadsFromBackup() {
    let files = FileManager.default
    let folders: [(FileManager.SearchPathDirectory, String)] = [
      (.documentDirectory, "bilibeat_audio"),
      (.applicationSupportDirectory, "bilibeat_covers"),
    ]
    for (base, name) in folders {
      guard let root = files.urls(for: base, in: .userDomainMask).first else { continue }
      var folder = root.appendingPathComponent(name, isDirectory: true)
      try? files.createDirectory(at: folder, withIntermediateDirectories: true)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try? folder.setResourceValues(values)
    }
  }
}
