import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    if MainFlutterWindow.isQuickMode() {
      // "עדכון מהיר": חלון קטן וממורכז (כמו ב-Windows), בגודל קבוע.
      self.title = "עדכון מסד הספרים"
      self.styleMask.remove(.resizable)
      self.standardWindowButton(.zoomButton)?.isEnabled = false
      self.setContentSize(NSSize(width: 400, height: 620))
      self.center()
    }

    super.awakeFromNib()
  }

  /// אותו תנאי כמו ב-Dart: --quick, או descriptor.json ו-installer.json ליד חבילת ה-.app
  /// (כך עדכוני אוצריא מפעילה את התוכנה).
  private static func isQuickMode() -> Bool {
    if CommandLine.arguments.contains("--quick") { return true }
    let dir = Bundle.main.bundleURL.deletingLastPathComponent()
    let fm = FileManager.default
    return fm.fileExists(atPath: dir.appendingPathComponent("descriptor.json").path)
      && fm.fileExists(atPath: dir.appendingPathComponent("installer.json").path)
  }
}
