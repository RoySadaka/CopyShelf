import AppKit
import Carbon.HIToolbox
import ServiceManagement
import os.log

final class CopyShelf: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let monitor: ClipboardMonitor
    private var timer: Timer?
    private var hotKeys: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private var target: NSRunningApplication?

    override init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let historyFile = folder.appendingPathComponent("CopyShelf/history.plist")
        monitor = ClipboardMonitor(pasteboard: .general, history: History(file: historyFile))
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let icon = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "CopyShelf")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.toolTip = "CopyShelf"
        statusItem.menu = menu
        menu.delegate = self

        let poll = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.monitor.captureIfChanged()
        }
        RunLoop.main.add(poll, forMode: .common)
        timer = poll
        installHotKeys()
        if CommandLine.arguments.contains("--register-at-login"), SMAppService.mainApp.status == .notRegistered {
            do {
                try SMAppService.mainApp.register()
            } catch {
                os_log("Could not register CopyShelf at login: %{public}@", error.localizedDescription)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        for hotKey in hotKeys { UnregisterEventHotKey(hotKey) }
        if let eventHandler = eventHandler { RemoveEventHandler(eventHandler) }
        monitor.history.finishSaving()
    }

    private func installHotKeys() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context = context else { return OSStatus(eventNotHandledErr) }
            let app = Unmanaged<CopyShelf>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { app.showHistoryAtPointer() }
            return noErr
        }, 1, &spec, context, &eventHandler)
        guard status == noErr else {
            os_log("Could not install CopyShelf shortcut handler: %d", status)
            return
        }
        for (index, modifiers) in [cmdKey | shiftKey, cmdKey | controlKey].enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: 0x43505348, id: UInt32(index + 1))
            let result = RegisterEventHotKey(
                UInt32(kVK_ANSI_V), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref
            )
            if result == noErr, let ref = ref {
                hotKeys.append(ref)
            } else {
                os_log("Could not register CopyShelf shortcut %d: %d", index + 1, result)
            }
        }
        os_log("CopyShelf registered %d clipboard shortcuts", hotKeys.count)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        target = NSWorkspace.shared.frontmostApplication
        monitor.captureIfChanged()
        menu.removeAllItems()

        let clips = monitor.history.clips
        if clips.isEmpty {
            menu.addItem(withTitle: "Copy something to start", action: nil, keyEquivalent: "")
        }
        for start in stride(from: 0, to: clips.count, by: 10) {
            let group = menu.addItem(withTitle: "\(start + 1)-\(start + 10)", action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: group.title)
            for (offset, clip) in clips[start..<min(start + 10, clips.count)].enumerated() {
                add(clip, to: submenu, key: String((offset + 1) % 10))
            }
            menu.setSubmenu(submenu, for: group)
        }

        menu.addItem(.separator())
        if !CGPreflightPostEventAccess() {
            command("Enable Automatic Paste…", #selector(enableAutomaticPaste))
        }
        if !clips.isEmpty {
            command("Clear History…", #selector(clearHistory))
        }
        let login = command("Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        command("Quit CopyShelf", #selector(quit))
    }

    private func showHistoryAtPointer() {
        menuNeedsUpdate(menu)
        let pointer = NSEvent.mouseLocation
        // Native menu tracking handles arrows, Escape, and screen-edge placement.
        // Queue Right in the tracking run loop to expand the selected first group.
        let expand = Timer(timeInterval: 0.08, repeats: false) { _ in
            if let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                context: nil, characters: String(UnicodeScalar(NSRightArrowFunctionKey)!),
                charactersIgnoringModifiers: String(UnicodeScalar(NSRightArrowFunctionKey)!),
                isARepeat: false, keyCode: UInt16(kVK_RightArrow)
            ) {
                NSApp.postEvent(event, atStart: true)
            }
        }
        if !monitor.history.clips.isEmpty {
            RunLoop.main.add(expand, forMode: .eventTracking)
        }
        menu.popUp(positioning: menu.items.first, at: pointer, in: nil)
        expand.invalidate()
    }

    private func add(_ clip: Clip, to menu: NSMenu, key: String) {
        let item = menu.addItem(withTitle: clip.title, action: #selector(paste(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = []
        item.target = self
        item.representedObject = clip
    }

    @discardableResult
    private func command(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func paste(_ sender: NSMenuItem) {
        guard let clip = sender.representedObject as? Clip, monitor.restore(clip) else { return }
        guard CGPreflightPostEventAccess(), let destination = target,
              destination.processIdentifier != NSRunningApplication.current.processIdentifier else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == destination.processIdentifier,
                  let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
            else { return }
            down.flags = .maskCommand
            up.flags = .maskCommand
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    @objc private func enableAutomaticPaste() {
        if !CGRequestPostEventAccess() {
            let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(settings)
        }
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            monitor.captureIfChanged()
            monitor.history.clear()
        }
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled: try service.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
            default: try service.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            NSAlert(error: error).runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

umask(0o077)
let app = NSApplication.shared
let delegate = CopyShelf()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
