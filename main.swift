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
    private var reportedFolders = Set<String>()
    private var checkingUpdate = false
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"

    override init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let historyFile = folder.appendingPathComponent("CopyShelf/history.plist")
        monitor = ClipboardMonitor(pasteboard: .general, history: History(file: historyFile),
                                   recoverImage: QuickLookImage.capture)
        super.init()
        monitor.onFolderAccessDenied = { [weak self] folder in self?.reportFolderAccess(folder) }
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
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != NSRunningApplication.current.processIdentifier {
            target = front
        }
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
        if !AXIsProcessTrusted() {
            command("Enable Automatic Paste…", #selector(enableAutomaticPaste))
        }
        command("Open Folder Settings…", #selector(openFolderSettings))
        if !clips.isEmpty {
            command("Clear History…", #selector(clearHistory))
        }
        let login = command("Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        command("About CopyShelf…", #selector(about))
        let update = command("Check for Updates…", #selector(checkForUpdates))
        update.isEnabled = !checkingUpdate
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
        guard AXIsProcessTrusted() else {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Allow CopyShelf to paste"
                alert.informativeText = "The selected text is on your clipboard. macOS has not authorized this copy of the app. Remove CopyShelf from Accessibility, add it again from Applications, and enable it."
                alert.addButton(withTitle: "Open Accessibility")
                alert.addButton(withTitle: "Later")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn { self.enableAutomaticPaste() }
            }
            return
        }
        guard let destination = target,
              destination.processIdentifier != NSRunningApplication.current.processIdentifier else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == NSRunningApplication.current.processIdentifier {
                destination.activate(options: .activateIgnoringOtherApps)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
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
    }

    @objc private func enableAutomaticPaste() {
        if !AXIsProcessTrusted() {
            let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(settings)
        }
    }

    private func reportFolderAccess(_ folder: String) {
        guard reportedFolders.insert(folder).inserted else { return }
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "CopyShelf needs access to \(folder) to copy this image."
            alert.informativeText = "In Files & Folders, expand CopyShelf and enable \(folder) Folder. Then return to Quick Look and press ⌘C again."
            alert.addButton(withTitle: "Open Folder Settings")
            alert.addButton(withTitle: "Later")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { self.openFolderSettings() }
        }
    }

    @objc private func openFolderSettings() {
        let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!
        NSWorkspace.shared.open(settings)
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

    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "CopyShelf",
            .applicationVersion: version,
            .credits: NSAttributedString(string: "A small, open-source clipboard manager.\nMIT License · Roy Sadaka"),
            .applicationIcon: NSImage(named: "AppIcon") ?? NSImage()
        ])
    }

    @objc private func checkForUpdates() {
        guard !checkingUpdate else { return }
        checkingUpdate = true
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/RoySadaka/CopyShelf/releases/latest")!)
        request.timeoutInterval = 20
        request.setValue("CopyShelf/" + version, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            let release = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let tag = release?["tag_name"] as? String
            DispatchQueue.main.async {
                self.checkingUpdate = false
                let alert = NSAlert()
                if error == nil, status == 200, let tag = tag {
                    let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                    if latest.compare(self.version, options: .numeric) == .orderedDescending {
                        alert.messageText = "CopyShelf \(latest) is available"
                        alert.informativeText = "You have version \(self.version). Download the new disk image, quit CopyShelf, and drag the updated app into Applications."
                        alert.addButton(withTitle: "Open Download")
                        alert.addButton(withTitle: "Later")
                        NSApp.activate(ignoringOtherApps: true)
                        if alert.runModal() == .alertFirstButtonReturn {
                            NSWorkspace.shared.open(URL(string: "https://github.com/RoySadaka/CopyShelf/releases/latest")!)
                        }
                        return
                    }
                    alert.messageText = "CopyShelf is up to date"
                    alert.informativeText = "You’re running version \(self.version)."
                } else {
                    alert.messageText = "Couldn’t check for updates"
                    alert.informativeText = error?.localizedDescription ?? "GitHub returned an unexpected response. Please try again later."
                }
                alert.addButton(withTitle: "OK")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }.resume()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

if CommandLine.arguments.contains("--permission-status") {
    print("Accessibility: \(AXIsProcessTrusted()); event posting: \(CGPreflightPostEventAccess())")
    exit(0)
}

umask(0o077)
let app = NSApplication.shared
let delegate = CopyShelf()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
