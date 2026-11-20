import AppKit

// Focus a window without raising it, so windows above it (e.g. floating windows) stay above.
//
// SkyLight private API, resolved with dlsym so that AeroSpace keeps working (with a regular raise+activate fallback)
// if Apple ever removes these symbols. Doesn't require disabling SIP.
// The technique is borrowed from yabai (window_manager_focus_window_without_raise / window_manager_make_key_window).

private typealias SetFrontProcessWithOptions = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32
private typealias PostEventRecordTo = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32
private typealias GetProcessForPid = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

private struct SkyLightFocusApi: Sendable {
    let setFrontProcessWithOptions: SetFrontProcessWithOptions
    let postEventRecordTo: PostEventRecordTo
    let getProcessForPid: GetProcessForPid

    static let shared: SkyLightFocusApi? = {
        guard let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let hiServices = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
              let setFront = dlsym(skyLight, "_SLPSSetFrontProcessWithOptions"),
              let post = dlsym(skyLight, "SLPSPostEventRecordTo"),
              let getPsn = dlsym(hiServices, "GetProcessForPID")
        else { return nil }
        return SkyLightFocusApi(
            setFrontProcessWithOptions: unsafeBitCast(setFront, to: SetFrontProcessWithOptions.self),
            postEventRecordTo: unsafeBitCast(post, to: PostEventRecordTo.self),
            getProcessForPid: unsafeBitCast(getPsn, to: GetProcessForPid.self),
        )
    }()
}

private let kCPSUserGenerated: UInt32 = 0x200
// yabai uses 0xf8, but it was reported to overrun on macOS 14.7 (Hammerspoon #370). The record itself still says 0xf8
private let eventRecordSize = 0x100

/// - Parameters:
///   - currentlyFocusedNativeWindowId: the focused window of the same app, if the app is already frontmost.
///     macOS needs explicit deactivate/activate records to switch the key window inside an already active app.
/// - Returns: false if the private API is unavailable or failed. The caller should fall back to a regular focus
@MainActor
func focusWithoutRaise(pid: pid_t, nativeWindowId: UInt32, currentlyFocusedNativeWindowId: UInt32?) -> Bool {
    guard let api = SkyLightFocusApi.shared else { return false }
    var psn = ProcessSerialNumber()
    guard api.getProcessForPid(pid, &psn) == noErr else { return false }

    if let currentlyFocusedNativeWindowId, currentlyFocusedNativeWindowId != nativeWindowId {
        var deactivate = eventRecord(windowId: currentlyFocusedNativeWindowId)
        deactivate[0x08] = 0x0d
        deactivate[0x8a] = 0x02
        _ = api.postEventRecordTo(&psn, &deactivate)
        // Some apps get confused if both records arrive at the same instant (yabai)
        usleep(10_000)
        var activate = eventRecord(windowId: nativeWindowId)
        activate[0x08] = 0x0d
        activate[0x8a] = 0x01
        _ = api.postEventRecordTo(&psn, &activate)
    }

    guard api.setFrontProcessWithOptions(&psn, nativeWindowId, kCPSUserGenerated) == 0 else { return false }

    // Make the window key
    var makeKey = eventRecord(windowId: nativeWindowId)
    makeKey[0x3a] = 0x10
    for i in 0x20 ..< 0x30 { makeKey[i] = 0xff }
    makeKey[0x08] = 0x01
    _ = api.postEventRecordTo(&psn, &makeKey)
    makeKey[0x08] = 0x02
    _ = api.postEventRecordTo(&psn, &makeKey)
    return true
}

private func eventRecord(windowId: UInt32) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: eventRecordSize)
    bytes[0x04] = 0xf8
    withUnsafeBytes(of: windowId.littleEndian) { for (i, b) in $0.enumerated() { bytes[0x3c + i] = b } }
    return bytes
}
