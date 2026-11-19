import Foundation
import SwiftUI
import Testing

struct LibraryLogicTests {
    @Test func clipboardKindPillsHaveContrastingSymbolsInBothAppearances() {
        func luminance(_ color: Color) -> Float {
            let c = color.resolve(in: EnvironmentValues())
            return 0.2126 * c.linearRed + 0.7152 * c.linearGreen + 0.0722 * c.linearBlue
        }
        let dark = CardMark.kindColors(in: .dark)
        let light = CardMark.kindColors(in: .light)
        #expect((luminance(dark.symbol) + 0.05) / (luminance(dark.fill) + 0.05) >= 3)
        #expect((luminance(light.fill) + 0.05) / (luminance(light.symbol) + 0.05) >= 3)
        #expect(light.fill == CardMark.fill && light.symbol == CardMark.text)
    }

    @Test func cachedShadowMatchesItsRoundedRectangleAfterResizing() {
        for width: CGFloat in [220, 314, 140, 220] {
            let bounds = CGRect(x: 2, y: 3, width: width, height: width - 30)
            for inset: CGFloat in [0, 1, 8, 10] {
                let radius = LibraryCardDensity(width: width).cornerRadius
                let shadow = LibraryShadowShape(inset: inset, radius: radius)
                let shape = RoundedRectangle(cornerRadius: radius, style: .circular).inset(by: inset)
                #expect(shadow.path(in: bounds) == shape.path(in: bounds))
            }
        }
    }

    @Test func stockCardDepthFollowsPointerAndDeletion() {
        let resting = LibraryCardDepth(hovering: false, pressed: false, deleting: false)
        let hover = LibraryCardDepth(hovering: true, pressed: false, deleting: false)
        let press = LibraryCardDepth(hovering: true, pressed: true, deleting: false)
        let deleting = LibraryCardDepth(hovering: true, pressed: true, deleting: true)
        #expect([resting.lift, hover.lift, press.lift, deleting.lift] == [0, -2, 2, 1])
        #expect([resting.lowerLip, hover.lowerLip, press.lowerLip, deleting.lowerLip] == [2, 2, 0.5, nil])
        #expect(resting.contact == .init(offset: 4, blur: 5, inset: 1))
        #expect(resting.key == .init(offset: 16, blur: 28, inset: 8))
        #expect(hover.contact == .init(offset: 6, blur: 6, inset: 1))
        #expect(hover.key == .init(offset: 26, blur: 40, inset: 10))
        #expect(press.contact == .init(offset: 1, blur: 1.5, inset: 0))
        #expect(press.key == nil && deleting.contact == nil && deleting.key == nil)
    }

    @Test func clipboardKindSymbolsKeepTheirSpokenNames() {
        for (kind, word, symbol): (LibraryClipKind, String, String) in [
            (.text, "text", "textformat"), (.code, "code", "chevron.left.forwardslash.chevron.right"), (.link, "link", "link")
        ] {
            #expect(kind.rawValue == word)
            #expect(kind.symbol == symbol)
        }
    }

    @Test func cardsUseTheCloudAndContentSlotsForTheirKind() {
        let url = "https://example.invalid/clip"
        func upload(_ kind: String) -> CloudUpload {
            CloudUpload(id: "clip", url: url, title: nil, filename: "Example", mediaType: kind, size: nil,
                        duration: kind == "video" ? 61 : nil, createdAt: .now, views: nil, thumbnailUrl: nil)
        }
        let screenshot = LibraryCardMarks(captureLink: nil, upload: nil, tall: true, recordingLength: nil)
        #expect(screenshot.cloud == .unshared && screenshot.content == [.tall])
        let recording = LibraryCardMarks(captureLink: url, upload: nil, tall: false, recordingLength: "1:01")
        #expect(recording.cloud == .shared && recording.content == [.duration("1:01")])
        #expect(LibraryCardMarks(upload: upload("video"), tall: false, localLength: nil).content == recording.content)
        var gallery = upload("gallery")
        gallery.galleryItemIDs = ["a", "b"]
        #expect(LibraryCardMarks(upload: gallery, tall: false, localLength: nil).content == [.gallery(2)])
        var file = upload("file")
        #expect(LibraryCardMarks(upload: file, tall: false, localLength: nil).cloud == .shared)
        file.requestId = "request"
        let received = LibraryCardMarks(upload: file, tall: false, localLength: nil)
        #expect(received.cloud == .received && received.content.isEmpty)
        for (kind, body, title, mark): (ClipboardEntryKind, String, String, LibraryCardMarks.Pill?) in [
            (.text, "let x = 42", "let x = 42", .kind(.code)),
            (.text, "https://example.org/path/end", "example.org/end", .kind(.link)),
            (.text, "#FBCA44", "#FBCA44", nil), (.text, "Meeting notes", "Meeting notes", .kind(.text)),
            (.snippet, "Greeting\nBody", "Greeting", nil), (.files, "/tmp/Notes.pdf", "Notes.pdf", nil),
            (.image, "", "1440 × 900", nil)
        ] {
            var clip = ClipboardEntry(id: "fixture", kind: kind, text: body, title: nil, imageURL: nil, libraryPath: nil,
                byteSize: 0, pixelWidth: 1440, pixelHeight: 900, sourceBundleID: nil, isRemote: false, firstCopiedAt: .now,
                lastCopiedAt: .now, timesCopied: 1, pinnedAt: .now)
            #expect(ClipboardList.gridTitle(of: clip) == title)
            let marks = LibraryCardMarks(clip: clip, upload: nil)
            #expect(marks.cloud == nil && marks.content == [mark].compactMap { $0 })
            clip.cloudLinks = [url]
            #expect(LibraryCardMarks(clip: clip, upload: nil).cloud == .shared)
        }
    }

    @Test func imageGridTitleUsesItsNameThenDescriptionThenDimensions() {
        func title(_ name: String?, _ description: String?, width: Int = 1440, height: Int = 900) -> String {
            var clip = ClipboardEntry(id: "image", kind: .image, text: nil, title: name, imageURL: nil,
                libraryPath: nil, byteSize: 0, pixelWidth: width, pixelHeight: height, sourceBundleID: nil,
                isRemote: false, firstCopiedAt: .now, lastCopiedAt: .now, timesCopied: 1, pinnedAt: nil)
            clip.modelTitle = description
            return ClipboardList.gridTitle(of: clip)
        }
        #expect(title("My screenshot", "Inbox") == "My screenshot")
        #expect(title(nil, "Inbox") == "Inbox")
        #expect(title(" ", nil) == "1440 × 900")
        #expect(title(nil, nil, width: 0, height: 0) == "Image")
    }

    @Test func cloudMediaRevisionSurvivesListingAndKeysPreviewRequests() throws {
        let data = Data("""
        {"uploads":[{"id":"abcd1234","url":"https://share.example.invalid/abcd1234","filename":"clip.mp4","mediaType":"video","createdAt":"2026-10-15T00:00:00Z","mediaKey":"uploads/abcd1234/media-new"}]}
        """.utf8)
        var upload = try #require(CloudUploadList.decode(data).uploads.first)
        #expect(upload.mediaKey == "uploads/abcd1234/media-new")
        let url = try #require(CloudPreviewCache.mediaURL(for: upload))
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "v", value: upload.mediaKey)])
        upload.mediaKey = nil
        #expect(CloudPreviewCache.mediaURL(for: upload)?.query == nil)
    }

    @Test func cloudPreviewReusesOnlyTheMatchingCachedRevision() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let directory = folder.appendingPathComponent("abcd1234")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let movie = directory.appendingPathComponent("clip.mp4")
        try Data("synthetic masked movie".utf8).write(to: movie)
        try "new-media".write(to: directory.appendingPathComponent(".media-key"), atomically: true, encoding: .utf8)
        var upload = CloudUpload(id: "abcd1234", url: "https://example.invalid/abcd1234", title: nil, filename: "clip.mp4",
            mediaType: "video", size: nil, duration: nil, createdAt: .distantPast, views: nil, thumbnailUrl: nil, mediaKey: "new-media")
        let cache = CloudPreviewCache(folder: folder, limit: 1024)
        let result = try await cache.file(for: upload)
        #expect(result.resolvingSymlinksInPath() == movie.resolvingSymlinksInPath())
        #expect(try Data(contentsOf: result) == Data("synthetic masked movie".utf8))
        upload.mediaKey = "replacement-media"
        #expect(try cache.cachedFile(for: upload) == nil)
        #expect(!FileManager.default.fileExists(atPath: movie.path))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("legacy unredacted movie".utf8).write(to: movie)
        #expect(try cache.cachedFile(for: upload) == nil)
        #expect(!FileManager.default.fileExists(atPath: movie.path))
    }

    @Test func aDownloadedReceivedFileBecomesTheCachedCopyOnce() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let downloaded = folder.appendingPathComponent("Report.pdf")
        try Data("synthetic received file".utf8).write(to: downloaded)
        let upload = CloudUpload(id: "recv1234", url: "https://example.invalid/recv1234", title: nil, filename: "Report.pdf",
            mediaType: "file", size: nil, duration: nil, createdAt: .distantPast, views: nil, thumbnailUrl: nil, requestId: "req1")
        let cache = CloudPreviewCache(folder: folder.appendingPathComponent("cache"), limit: 1024)
        #expect(try cache.cachedFile(for: upload, touching: false) == nil)
        try cache.adopt(downloaded, for: upload)
        let cached = try #require(try cache.cachedFile(for: upload, touching: false))
        #expect(cached.pathExtension == "pdf")
        #expect(try Data(contentsOf: cached) == Data("synthetic received file".utf8))
        // A second download doesn't replace the copy Quick Look may be showing.
        try Data("second download".utf8).write(to: downloaded)
        try cache.adopt(downloaded, for: upload)
        #expect(try Data(contentsOf: cached) == Data("synthetic received file".utf8))
    }

    @Test func replacementOnlyTargetsTheConfiguredWorker() {
        let base = "https://share.example.invalid"
        #expect(CloudUploadList.replacementID(of: base + "/abcd1234", workerBase: base) == "abcd1234")
        for link in ["https://other.invalid/abcd1234", "http://share.example.invalid/abcd1234",
                     base + ":8443/abcd1234", base + "/api/upload/abcd1234", base + "/../abcd1234",
                     base + "/bad%2Fid", base + "/", "not a link"] {
            #expect(CloudUploadList.replacementID(of: link, workerBase: base) == nil)
        }
        #expect(CloudUploadList.replacementID(of: nil, workerBase: base) == nil)
    }

    private func comment(_ id: String, second: TimeInterval) -> CloudComment {
        CloudComment(id: id, uploadId: "fixture", authorName: "Fixture", authorAvatar: nil,
                     text: "test", timestamp: nil, createdAt: Date(timeIntervalSince1970: second),
                     upload: .init(title: nil, filename: "test.png", mediaType: "image",
                                   shareUrl: "https://example.invalid/fixture", expiresAt: nil))
    }

    @Test func watermarkDistinguishesSameSecondIDs() throws {
        let a = comment("a", second: 1), b = comment("b", second: 2), c = comment("c", second: 2)
        let mark = try #require(FeedWatermark.reading([a, b], after: nil))
        #expect(!mark.isUnread(a) && !mark.isUnread(b))
        #expect(mark.isUnread(c))
        #expect(mark.isUnread(comment("d", second: 3)))
        let both = try #require(FeedWatermark.reading([c], after: mark))
        #expect(both.ids == ["b", "c"])
        #expect(!both.isUnread(b) && !both.isUnread(c))
    }

    @Test func watermarkNeverMovesBackAndSurvivesStorage() throws {
        #expect(FeedWatermark.reading([CloudComment](), after: nil) == nil)
        let mark = try #require(FeedWatermark.reading([comment("b", second: 2)], after: nil))
        #expect(FeedWatermark.reading([comment("a", second: 1)], after: mark) == mark)
        #expect(FeedWatermark.reading([CloudComment](), after: mark) == mark)
        let stored = try JSONDecoder().decode(FeedWatermark.self, from: JSONEncoder().encode(mark))
        #expect(stored == mark && !stored.isUnread(comment("b", second: 2)))
    }

    private func like(_ id: String, second: TimeInterval) -> CloudLike {
        CloudLike(id: id, uploadId: "fixture", createdAt: Date(timeIntervalSince1970: second),
                  upload: .init(title: nil, filename: "test.png", mediaType: "image",
                                shareUrl: "https://example.invalid/fixture", expiresAt: nil))
    }

    @Test func watermarkReadsLikesLikeComments() throws {
        let a = like("a", second: 1), b = like("b", second: 2), c = like("c", second: 2)
        let mark = try #require(FeedWatermark.reading([a, b], after: nil))
        #expect(!mark.isUnread(a) && !mark.isUnread(b))
        #expect(mark.isUnread(c) && mark.isUnread(like("d", second: 3)))
        #expect(FeedWatermark.reading([like("e", second: 1)], after: mark) == mark)
        let stored = try JSONDecoder().decode(FeedWatermark.self, from: JSONEncoder().encode(mark))
        #expect(stored == mark && !stored.isUnread(b))
    }

    @Test func likePageDecodesTheSpecShape() throws {
        let data = Data(#"""
        {"likes":[
          {"id":"lk_b","uploadId":"up1","createdAt":"2026-10-09T05:55:30Z",
           "upload":{"title":null,"filename":"shot.png","mediaType":"image","shareUrl":"https://example.invalid/up1","expiresAt":null}},
          {"id":"lk_a","uploadId":"up2","createdAt":"2026-10-09T05:55:30Z",
           "upload":{"title":"Demo","filename":"clip.mov","mediaType":"video","shareUrl":"https://example.invalid/up2","expiresAt":"2026-11-01T00:00:00Z"}},
          {"id":"lk_c","uploadId":"up3","createdAt":"2026-10-09T05:50:00Z",
           "upload":{"title":"","filename":"x.png","mediaType":"image","shareUrl":"https://example.invalid/up3","expiresAt":null}}
        ],"next":500}
        """#.utf8)
        let page = try CloudLikeList.decode(data)
        #expect(page.next == 500)
        #expect(page.likes.map(\.uploadName) == ["shot.png", "Demo", "x.png"])
        #expect(page.likes.map(\.isVideo) == [false, true, false])
        #expect(page.likes[0].createdAt == Date(timeIntervalSince1970: 1_791_525_330))
        let empty = try CloudLikeList.decode(Data(#"{"likes":[],"next":null}"#.utf8))
        #expect(empty.likes.isEmpty && empty.next == nil)
    }

    @Test func likeRequestAndShareLink() throws {
        let request = try #require(CloudLikeList.request(workerBase: "https://example.invalid", token: "t0k", offset: 500))
        #expect(request.url?.absoluteString == "https://example.invalid/api/likes?limit=500&offset=500")
        #expect(request.httpMethod == "GET" && request.value(forHTTPHeaderField: "Authorization") == "Bearer t0k")
        #expect(CloudLikeList.request(workerBase: "not a url", token: "t", offset: 0) == nil)
        func link(_ shareUrl: String) -> URL? {
            CloudLikeList.shareLink(for: CloudLike(id: "a", uploadId: "u", createdAt: .distantPast, upload: .init(
                title: nil, filename: "test.png", mediaType: "image", shareUrl: shareUrl, expiresAt: nil)))
        }
        #expect(link("https://example.invalid/u")?.absoluteString == "https://example.invalid/u")
        #expect(link("javascript:alert(1)") == nil)
        #expect(link("file:///etc/hosts") == nil)
        #expect(link("https://") == nil)
    }

    @Test func uploadPagingKeepsFirstOccurrenceWhenOffsetsShift() throws {
        func row(_ id: Int, title: String = "first") -> String {
            #"{"id":"up\#(id)","url":"https://example.invalid/\#(id)","filename":"test.png","title":"\#(title)","mediaType":"image","createdAt":"2026-10-09T00:00:00Z"}"#
        }
        func page(_ rows: [String]) throws -> [CloudUpload] {
            try CloudUploadList.decode(Data(("{\"uploads\":[" + rows.joined(separator: ",") + "]}").utf8)).uploads
        }
        let first = try page((0..<500).map { row($0) })
        let second = try page([row(499, title: "repeated")] + (500..<1000).map { row($0) })
        let listed = CloudUploadList.deduplicated(first + second)
        #expect(listed.count == 1000)
        #expect(listed.map(\.id) == (0..<1000).map { "up\($0)" })
        #expect(listed[499].title == "first")
    }

    @Test func uploadDedupePreservesUniqueAndEmptyLists() throws {
        #expect(CloudUploadList.deduplicated([]).isEmpty)
        let data = Data(#"{"uploads":[{"id":"a","url":"https://example.invalid/a","filename":"test.png","mediaType":"image","createdAt":"2026-10-09T00:00:00Z"}]}"#.utf8)
        let uploads = try CloudUploadList.decode(data).uploads
        #expect(CloudUploadList.deduplicated(uploads) == uploads)
    }

    @Test func tagMatchesRankExactPrefixThenContainsStably() {
        let tags = ["Onboarding", "Design", "Long note", "On", "Bug", "online"]
        #expect(CaptureTagField.matches("on", in: tags) == ["On", "Onboarding", "online", "Long note"])
        #expect(CaptureTagField.matches("  ON \n", in: tags) == ["On", "Onboarding", "online", "Long note"])
        #expect(CaptureTagField.matches("de", in: tags) == ["Design"])
    }

    @Test func tagMatchesEmptyAndAbsentQueries() {
        let tags = ["Onboarding", "Design", "Long note", "On", "Bug", "online"]
        #expect(CaptureTagField.matches("", in: tags) == tags)
        #expect(CaptureTagField.matches(" \n", in: tags) == tags)
        #expect(CaptureTagField.matches("zzz", in: tags).isEmpty)
        #expect(CaptureTagField.matches("on", in: []).isEmpty)
    }
}
