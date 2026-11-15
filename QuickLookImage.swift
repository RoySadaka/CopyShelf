import AppKit
import UniformTypeIdentifiers

enum QuickLookImage {
    // Quick Look's Live Text layer can publish empty text for Command-C.
    // Recover only the single image whose filename matches the visible preview.
    static func capture(after clip: Clip) -> Clip? {
        guard clip.items.count == 1, clip.items[0].plainText == "",
              AXIsProcessTrusted(),
              let finder = NSWorkspace.shared.frontmostApplication,
              finder.bundleIdentifier == "com.apple.finder" else { return nil }
        let application = AXUIElementCreateApplication(finder.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.2)
        let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard let preview = windows.first(where: {
            attribute($0, kAXTitleAttribute) as? String == "Quick Look"
        }), let name = previewFilename(preview, depth: 0) else { return nil }

        let candidates = windows.flatMap { selectedURLs($0, depth: 0) }.filter {
            (try? $0.resourceValues(forKeys: [.nameKey]).name) == name
        }
        let unique = Set(candidates)
        guard unique.count == 1, let url = unique.first,
              let type = UTType(filenameExtension: name.components(separatedBy: ".").last ?? ""),
              type.conforms(to: .image),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 20 * 1024 * 1024,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 20 * 1024 * 1024 + 1),
              data.count <= 20 * 1024 * 1024, NSImage(data: data) != nil else { return nil }

        let scratch = NSPasteboard.withUniqueName()
        defer { scratch.releaseGlobally() }
        scratch.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        return Clip(pasteboard: scratch)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return value
    }

    private static func previewFilename(_ element: AXUIElement, depth: Int) -> String? {
        guard depth < 8 else { return nil }
        if let identifier = attribute(element, kAXIdentifierAttribute) as? String,
           identifier.hasPrefix("Image Preview: ") {
            return String(identifier.dropFirst("Image Preview: ".count))
        }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if let name = previewFilename(child, depth: depth + 1) { return name }
        }
        return nil
    }

    private static func selectedURLs(_ element: AXUIElement, depth: Int) -> [URL] {
        guard depth < 8 else { return [] }
        if let rows = attribute(element, kAXSelectedRowsAttribute) as? [AXUIElement], !rows.isEmpty {
            return rows.flatMap { fileURLs($0, depth: 0) }
        }
        return (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
            .flatMap { selectedURLs($0, depth: depth + 1) }
    }

    private static func fileURLs(_ element: AXUIElement, depth: Int) -> [URL] {
        guard depth < 5 else { return [] }
        if let url = attribute(element, kAXURLAttribute) as? URL, url.isFileURL { return [url] }
        return (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
            .flatMap { fileURLs($0, depth: depth + 1) }
    }
}
