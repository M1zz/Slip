import AppKit
import Carbon.HIToolbox

/// Thin Swift wrapper around Carbon's `RegisterEventHotKey`.
///
/// Carbon is still the only supported API for global hotkeys on macOS. We keep
/// this as our only Carbon contact surface so the rest of the app can be
/// straight AppKit/SwiftUI.
///
/// Thread-safety: `register()` / `unregister()` must be called on the main
/// thread. The callback fires on the main thread via the shared event handler.
final class GlobalHotkey {

    struct Modifiers: OptionSet {
        let rawValue: UInt32
        static let command = Modifiers(rawValue: UInt32(cmdKey))
        static let option  = Modifiers(rawValue: UInt32(optionKey))
        static let control = Modifiers(rawValue: UInt32(controlKey))
        static let shift   = Modifiers(rawValue: UInt32(shiftKey))
    }

    private let keyCode: UInt32
    private let modifiers: Modifiers
    private let handler: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var signature: UInt32 = 0
    private var id: UInt32 = 0

    init(keyCode: UInt32, modifiers: Modifiers, handler: @escaping () -> Void) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.handler = handler
    }

    func register() {
        Self.installEventHandlerOnce()

        let id = Self.nextID()
        self.id = id
        self.signature = Self.fourCharCode("SLIP")
        let hotKeyID = EventHotKeyID(signature: signature, id: id)

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode, modifiers.rawValue, hotKeyID,
            GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr, let ref {
            self.hotKeyRef = ref
            Self.registry[id] = self
        } else {
            NSLog("GlobalHotkey: RegisterEventHotKey failed (status=\(status))")
        }
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        Self.registry.removeValue(forKey: id)
    }

    deinit { unregister() }

    // MARK: - Shared plumbing

    private static var registry: [UInt32: GlobalHotkey] = [:]
    private static var nextIDCounter: UInt32 = 1
    private static var handlerInstalled = false

    private static func nextID() -> UInt32 {
        defer { nextIDCounter += 1 }
        return nextIDCounter
    }

    private static func fourCharCode(_ s: String) -> UInt32 {
        var result: UInt32 = 0
        for char in s.unicodeScalars.prefix(4) {
            result = (result << 8) + (UInt32(char.value) & 0xFF)
        }
        return result
    }

    private static func installEventHandlerOnce() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, _) -> OSStatus in
                guard let event else { return noErr }
                var hotKeyID = EventHotKeyID()
                let err = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
                )
                if err == noErr, let hotkey = GlobalHotkey.registry[hotKeyID.id] {
                    DispatchQueue.main.async { hotkey.handler() }
                }
                return noErr
            },
            1, &spec, nil, nil
        )
    }
}
