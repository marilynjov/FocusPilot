import AppKit
import ApplicationServices
import FocusPilotCore

/// Brings forward the Warp window FocusPilot started for a task, found by
/// its title through Accessibility (decision 0005; Warp has no AppleScript
/// dictionary). Which window and what to tell the owner are decided in
/// `AgentWorkspace`; this only talks to macOS. Only for the owner's click.
@MainActor
enum WarpWindows {
    /// Whether FocusPilot may use Accessibility. With `prompting`, macOS
    /// shows its own request to turn it on in System Settings.
    static func isAllowed(prompting: Bool) -> Bool {
        // The value of `kAXTrustedCheckOptionPrompt`, named here because the
        // imported global isn't concurrency-safe in Swift 6.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompting] as CFDictionary)
    }

    /// Raises the first of the app's windows titled exactly `title`,
    /// unminimizing it first. False if none has the title or it would not
    /// come forward. The caller brings the app itself forward afterwards.
    static func raise(titled title: String, pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        // Warp answers at once or not at all; don't hold the app for the
        // default six seconds.
        AXUIElementSetMessagingTimeout(app, 1)
        guard let windows = value(kAXWindowsAttribute, of: app) as? [AXUIElement],
              let index = AgentWorkspace.window(titled: title, in: windows.map { value(kAXTitleAttribute, of: $0) as? String })
        else { return false }
        let window = windows[index]
        if value(kAXMinimizedAttribute, of: window) as? Bool == true {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        return AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
    }

    private static func value(_ attribute: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }
}
