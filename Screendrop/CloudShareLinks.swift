//
//  CloudShareLinks.swift
//  Screendrop
//
//  Every place the app copies, opens or shares a cloud link goes through
//  here, so an encrypted upload's link carries its key after `#`.
//

import AppKit

extension CloudShareKeys {
    static let live = CloudShareKeys(
        read: { CloudCredentialStore.getKeychainItem(key: $0) },
        write: { CloudCredentialStore.setKeychainItem(key: $0, value: $1) },
        delete: { CloudCredentialStore.deleteKeychainItem(key: $0) }
    )
}

enum CloudShareLinks {
    /// Each link with its key when this Mac has one. An encrypted upload whose
    /// key isn't here, such as one shared from the other Mac, goes without it,
    /// and an alert says so.
    static func links(_ urls: [String]) -> [String] {
        var missing = 0
        let links = urls.map { url in
            let id = CloudUploadList.uploadID(of: url)
            let key = id.flatMap { CloudShareKeys.live.key(uploadID: $0) }
            if key == nil, let id, CloudLibraryModel.shared.isEncrypted(id) { missing += 1 }
            return CloudShareSeal.link(url, key: key)
        }
        if missing > 0 { warnMissingKeys(missing) }
        return links
    }

    static func link(_ url: String) -> String {
        links([url])[0]
    }

    static func open(_ url: String) {
        if let url = URL(string: link(url)) { NSWorkspace.shared.open(url) }
    }

    static func copy(_ urls: [String]) {
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(links(urls).joined(separator: "\n"), forType: .string)
    }

    /// Shown after the link is copied or opened, not in its way.
    private static func warnMissingKeys(_ count: Int) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = count == 1 ? "This Mac doesn’t have this link’s key" : "This Mac doesn’t have these links’ keys"
            alert.informativeText = "Encrypted links keep their key on the Mac that shared them. Without it, the link opens a page that can’t show the file. Copy the link on that Mac instead."
            alert.runModal()
        }
    }
}
