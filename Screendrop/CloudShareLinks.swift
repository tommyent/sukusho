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
        write: { CloudCredentialStore.setKeychainItem(key: $0, value: $1, label: $2) },
        delete: { CloudCredentialStore.deleteKeychainItem(key: $0) },
        list: { CloudCredentialStore.keychainItems(prefix: CloudShareKeys.accountPrefix) }
    )
}

enum CloudShareLinks {
    /// Keys the Keychain refused, for this run only, so the links handed out now still carry them.
    private static var unsavedKeys: [String: String] = [:]

    /// Each link with its key when this Mac has one. A sealed upload whose key isn't here,
    /// such as one shared from the other Mac, goes without it, and an alert says so. `encrypted`
    /// is the upload's own record, from its list or feed item; this Mac's record of what it
    /// sealed and the Cloud list also count.
    static func links(_ items: [(url: String, encrypted: Bool)]) -> [String] {
        var missing = 0
        let links = items.map { item in
            let shown = shown(item.url, encrypted: item.encrypted)
            if shown.missingKey { missing += 1 }
            return shown.link
        }
        if missing > 0 { warnMissingKeys(missing) }
        return links
    }

    /// Links from this Mac's own captures: its record of what it sealed and the Cloud list decide.
    static func links(_ urls: [String]) -> [String] {
        links(urls.map { ($0, false) })
    }

    /// The link to show or hand out, and whether it lacks a key it needs; no alert.
    static func shown(_ url: String, encrypted: Bool = false) -> (link: String, missingKey: Bool) {
        guard let id = CloudUploadList.uploadID(of: url) else { return (url, false) }
        if let key = unsavedKeys[id] { return (CloudShareSeal.link(url, key: key), false) }
        return CloudShareKeys.live.link(url, uploadID: id, encrypted: encrypted || CloudSealedUploads().contains(id)
                                        || CloudLibraryModel.shared.isEncrypted(id))
    }

    static func open(_ url: String, encrypted: Bool = false) {
        if let url = links([(url, encrypted)]).first.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
    }

    static func copy(_ items: [(url: String, encrypted: Bool)]) {
        guard !items.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(links(items).joined(separator: "\n"), forType: .string)
    }

    static func copy(_ urls: [String]) {
        copy(urls.map { ($0, false) })
    }

    /// Keeps a new encrypted upload's key before its link is handed out. When the Keychain
    /// refuses it, the user can try again or see the whole link once; until the app quits,
    /// the links it hands out still carry the key.
    static func keep(_ key: String, uploadID: String, url: String) {
        CloudSealedUploads().insert(uploadID)
        while !CloudShareKeys.live.save(key, uploadID: uploadID, workerHost: CloudShareKeys.host(of: url) ?? "") {
            let alert = NSAlert()
            alert.messageText = "This link’s key couldn’t be saved"
            alert.informativeText = "The Keychain refused it, so this Mac can’t add the key to the link later. Try again, or show the whole link once and keep it somewhere safe."
            alert.addButton(withTitle: "Try Again")
            alert.addButton(withTitle: "Show Link")
            if alert.runModal() == .alertFirstButtonReturn { continue }
            unsavedKeys[uploadID] = key
            let shown = NSAlert()
            shown.messageText = "Encrypted link"
            shown.informativeText = "It won’t be shown again. Until Sukusho quits, links it copies still carry the key."
            let field = NSTextField(wrappingLabelWithString: CloudShareSeal.link(url, key: key))
            field.isSelectable = true
            field.frame = NSRect(x: 0, y: 0, width: 360, height: 48)
            shown.accessoryView = field
            shown.runModal()
            return
        }
    }

    /// Deleting an upload deletes its key and this Mac's record of it.
    static func forget(uploadID: String) {
        CloudShareKeys.live.remove(uploadID: uploadID)
        CloudSealedUploads().remove([uploadID])
        unsavedKeys[uploadID] = nil
    }

    /// After a complete Cloud list of `worker`, asked for at `listedSince`: drops the keys of
    /// its uploads that are gone, such as expired ones.
    static func prune(keeping uploadIDs: Set<String>, worker: String?, listedSince: Date) {
        guard let host = worker.flatMap(CloudShareKeys.host(of:)) else { return }
        CloudSealedUploads().remove(CloudShareKeys.live.prune(workerHost: host, keeping: uploadIDs, listedSince: listedSince))
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
