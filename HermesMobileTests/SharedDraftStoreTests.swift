import XCTest
@testable import HermesMobile

final class SharedDraftStoreTests: XCTestCase {
    func testDraftTextCombinesTextAndURLsInOrder() {
        let draft = HermesShareDraft.draftText(
            textSnippets: [
                "  Summarize this page  ",
                "\nSummarize this page\n",
                "Key quote",
                "https://example.com/article"
            ],
            urls: [
                URL(string: "https://example.com/article")!,
                URL(string: "https://example.com/article")!,
                URL(string: "https://example.com/notes")!
            ]
        )

        XCTAssertEqual(
            draft,
            """
            Summarize this page

            Key quote

            https://example.com/article

            https://example.com/notes
            """
        )
    }

    func testDraftTextIgnoresEmptyInput() {
        let draft = HermesShareDraft.draftText(textSnippets: [" \n\t "], urls: [])

        XCTAssertEqual(draft, "")
    }

    func testComposerDraftAddsTrailingNewlineForFollowupInput() {
        XCTAssertEqual(
            HermesShareDraft.composerDraft(from: "  https://example.com/article  "),
            "https://example.com/article\n"
        )
        XCTAssertEqual(HermesShareDraft.composerDraft(from: " \n\t "), "")
    }

    func testShareOpenURLRecognizesOnlyHermesShareLinks() {
        let scheme = HermesShareDraft.urlScheme

        XCTAssertTrue(HermesShareDraft.isShareOpenURL(URL(string: "\(scheme)://share")!))
        XCTAssertFalse(HermesShareDraft.isShareOpenURL(URL(string: "\(scheme)://settings")!))
        XCTAssertFalse(HermesShareDraft.isShareOpenURL(URL(string: "https://example.com/share")!))
    }

    func testPendingDraftStorageLoadsAndClearsDraft() throws {
        let directory = try temporaryDirectory()

        try HermesShareDraft.savePendingDraft(
            "  Draft from Safari  ",
            in: directory,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let draft = try HermesShareDraft.loadPendingDraft(from: directory)
        XCTAssertEqual(draft, "Draft from Safari")
        XCTAssertNil(try HermesShareDraft.loadPendingDraft(from: directory))
    }

    func testPendingImportStorageLoadsAttachmentAndClearsStagedFiles() throws {
        let directory = try temporaryDirectory()
        let attachmentData = Data("pdf bytes".utf8)

        try HermesShareDraft.savePendingImport(
            draft: "  Review this  ",
            attachments: [
                SharedAttachmentImport(
                    filename: "/private/tmp/report.pdf",
                    typeIdentifier: "com.adobe.pdf",
                    data: attachmentData
                )
            ],
            in: directory,
            now: Date(timeIntervalSince1970: 1_800_000_001)
        )

        let sharedImport = try XCTUnwrap(try HermesShareDraft.loadPendingImport(from: directory))

        XCTAssertEqual(sharedImport.draft, "Review this")
        XCTAssertEqual(sharedImport.attachments.count, 1)
        XCTAssertEqual(sharedImport.attachments.first?.filename, "report.pdf")
        XCTAssertEqual(sharedImport.attachments.first?.typeIdentifier, "com.adobe.pdf")
        XCTAssertEqual(sharedImport.attachments.first?.data, attachmentData)
        XCTAssertNil(try HermesShareDraft.loadPendingImport(from: directory))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(HermesShareDraft.pendingAttachmentsDirectoryName).path
            )
        )
    }

    // Reserving runs on the main actor during share handoff, so staged files
    // are mapped there and only paged in when the upload reads them.
    func testReservedAttachmentsAreMappedFromStagedFiles() throws {
        let directory = try temporaryDirectory()
        let attachmentData = Data(repeating: 0x42, count: 1_024 * 1_024)

        try HermesShareDraft.savePendingImport(
            draft: "",
            attachments: [
                SharedAttachmentImport(filename: "scan.pdf", typeIdentifier: "com.adobe.pdf", data: attachmentData)
            ],
            in: directory
        )

        let reservation = try XCTUnwrap(try HermesShareDraft.reserveNextPendingImport(from: directory))
        let attachment = try XCTUnwrap(reservation.sharedImport.attachments.first)

        XCTAssertTrue(isFileBacked(attachment.data), "staged files must be mapped, not read into memory")

        // The app consumes the reservation before uploading, so the first read
        // of the mapped bytes happens after their staged file is removed.
        try HermesShareDraft.consume(reservation, from: directory)
        XCTAssertEqual(attachment.data, attachmentData, "the mapping outlives the consumed reservation")
    }

    func testPendingImportSupportsAttachmentOnlyShare() throws {
        let directory = try temporaryDirectory()

        try HermesShareDraft.savePendingImport(
            draft: " \n ",
            attachments: [
                SharedAttachmentImport(
                    filename: "photo.jpg",
                    typeIdentifier: "public.jpeg",
                    data: Data([0x01, 0x02, 0x03])
                )
            ],
            in: directory
        )

        let sharedImport = try XCTUnwrap(try HermesShareDraft.loadPendingImport(from: directory))

        XCTAssertEqual(sharedImport.draft, "")
        XCTAssertEqual(sharedImport.attachments.first?.filename, "photo.jpg")
        XCTAssertEqual(sharedImport.attachments.first?.data, Data([0x01, 0x02, 0x03]))
    }

    func testPendingImportKeepsMultipleUploadableAttachments() throws {
        let directory = try temporaryDirectory()

        try HermesShareDraft.savePendingImport(
            draft: "",
            attachments: [
                SharedAttachmentImport(
                    filename: "first.txt",
                    typeIdentifier: "public.plain-text",
                    data: Data("first".utf8)
                ),
                SharedAttachmentImport(
                    filename: "second.txt",
                    typeIdentifier: "public.plain-text",
                    data: Data("second".utf8)
                )
            ],
            in: directory
        )

        let sharedImport = try XCTUnwrap(try HermesShareDraft.loadPendingImport(from: directory))

        XCTAssertEqual(sharedImport.attachments.map(\.filename), ["first.txt", "second.txt"])
        XCTAssertEqual(sharedImport.attachments.map(\.data), [Data("first".utf8), Data("second".utf8)])
    }

    func testPendingImportCapsAttachmentsAtSharedLimit() throws {
        let directory = try temporaryDirectory()
        let attachments = (0..<(HermesShareDraft.maximumSharedAttachmentCount + 1)).map { index in
            SharedAttachmentImport(
                filename: "file-\(index).txt",
                typeIdentifier: "public.plain-text",
                data: Data("file-\(index)".utf8)
            )
        }

        try HermesShareDraft.savePendingImport(
            draft: "",
            attachments: attachments,
            in: directory
        )

        let sharedImport = try XCTUnwrap(try HermesShareDraft.loadPendingImport(from: directory))

        XCTAssertEqual(sharedImport.attachments.count, HermesShareDraft.maximumSharedAttachmentCount)
        XCTAssertEqual(sharedImport.attachments.first?.filename, "file-0.txt")
        XCTAssertEqual(sharedImport.attachments.last?.filename, "file-9.txt")
    }

    func testInboxKeepsTwoSharesAndReservesThemOldestFirst() throws {
        let directory = try temporaryDirectory()
        let firstDate = Date(timeIntervalSince1970: 1_800_000_010)
        let secondDate = Date(timeIntervalSince1970: 1_800_000_020)

        try HermesShareDraft.savePendingDraft("First share", in: directory, now: firstDate)
        try HermesShareDraft.savePendingDraft("Second share", in: directory, now: secondDate)
        XCTAssertTrue(try HermesShareDraft.hasPendingImport(in: directory, now: secondDate))

        let first = try XCTUnwrap(
            try HermesShareDraft.reserveNextPendingImport(from: directory, now: secondDate)
        )
        XCTAssertEqual(first.sharedImport.draft, "First share")
        XCTAssertEqual(first.createdAt, firstDate)
        XCTAssertTrue(try HermesShareDraft.hasPendingImport(in: directory, now: secondDate))
        try HermesShareDraft.consume(first, from: directory)

        let second = try XCTUnwrap(
            try HermesShareDraft.reserveNextPendingImport(from: directory, now: secondDate)
        )
        XCTAssertEqual(second.sharedImport.draft, "Second share")
        XCTAssertEqual(second.createdAt, secondDate)
        try HermesShareDraft.consume(second, from: directory)

        XCTAssertFalse(try HermesShareDraft.hasPendingImport(in: directory, now: secondDate))
        XCTAssertNil(try HermesShareDraft.reserveNextPendingImport(from: directory, now: secondDate))
    }

    func testInboxDeduplicatesRepeatedPendingContent() throws {
        let directory = try temporaryDirectory()

        try HermesShareDraft.savePendingDraft(
            "Repeated share",
            in: directory,
            now: Date(timeIntervalSince1970: 1_800_000_030)
        )
        try HermesShareDraft.savePendingDraft(
            "Repeated share",
            in: directory,
            now: Date(timeIntervalSince1970: 1_800_000_040)
        )

        let reservation = try XCTUnwrap(
            try HermesShareDraft.reserveNextPendingImport(from: directory)
        )
        try HermesShareDraft.savePendingDraft(
            "Repeated share",
            in: directory,
            now: Date(timeIntervalSince1970: 1_800_000_050)
        )
        try HermesShareDraft.consume(reservation, from: directory)

        XCTAssertNil(try HermesShareDraft.reserveNextPendingImport(from: directory))
    }

    func testReleasedReservationCanBeReservedAgain() throws {
        let directory = try temporaryDirectory()
        try HermesShareDraft.savePendingDraft("Route me later", in: directory)

        let first = try XCTUnwrap(
            try HermesShareDraft.reserveNextPendingImport(from: directory)
        )
        try HermesShareDraft.release(first, in: directory)

        let second = try XCTUnwrap(
            try HermesShareDraft.reserveNextPendingImport(from: directory)
        )
        XCTAssertEqual(second.itemID, first.itemID)
        XCTAssertNotEqual(second.reservationID, first.reservationID)
        XCTAssertEqual(second.sharedImport, first.sharedImport)
    }

    func testExpiredReservationReturnsToInboxWithNewOwnership() throws {
        let directory = try temporaryDirectory()
        let reservationDate = Date(timeIntervalSince1970: 1_800_000_050)
        try HermesShareDraft.savePendingDraft("Recover me", in: directory, now: reservationDate)

        let expired = try XCTUnwrap(
            try HermesShareDraft.reserveNextPendingImport(from: directory, now: reservationDate)
        )
        let recovered = try XCTUnwrap(
            try HermesShareDraft.reserveNextPendingImport(
                from: directory,
                now: reservationDate.addingTimeInterval(HermesShareDraft.reservationLifetime + 1)
            )
        )

        XCTAssertEqual(recovered.itemID, expired.itemID)
        XCTAssertNotEqual(recovered.reservationID, expired.reservationID)
        XCTAssertThrowsError(try HermesShareDraft.consume(expired, from: directory))
        try HermesShareDraft.consume(recovered, from: directory)
    }

    func testMissingAttachmentOnlyItemDoesNotBlockLaterShare() throws {
        let directory = try temporaryDirectory()
        let attachmentDate = Date(timeIntervalSince1970: 1_800_000_060)
        try HermesShareDraft.savePendingImport(
            draft: "",
            attachments: [
                SharedAttachmentImport(
                    filename: "missing.txt",
                    typeIdentifier: "public.plain-text",
                    data: Data("gone".utf8)
                )
            ],
            in: directory,
            now: attachmentDate
        )
        try HermesShareDraft.savePendingDraft(
            "Still valid",
            in: directory,
            now: attachmentDate.addingTimeInterval(1)
        )

        for fileURL in try attachmentFileURLs(in: directory) {
            try FileManager.default.removeItem(at: fileURL)
        }

        let reservation = try XCTUnwrap(
            try HermesShareDraft.reserveNextPendingImport(from: directory)
        )
        XCTAssertEqual(reservation.sharedImport.draft, "Still valid")
        try HermesShareDraft.consume(reservation, from: directory)
        XCTAssertNil(try HermesShareDraft.reserveNextPendingImport(from: directory))
    }

    func testMissingAttachmentDoesNotDiscardRemainingSharedContent() throws {
        let directory = try temporaryDirectory()
        try HermesShareDraft.savePendingImport(
            draft: "Review what remains",
            attachments: [
                SharedAttachmentImport(
                    filename: "first.txt",
                    typeIdentifier: "public.plain-text",
                    data: Data("first".utf8)
                ),
                SharedAttachmentImport(
                    filename: "second.txt",
                    typeIdentifier: "public.plain-text",
                    data: Data("second".utf8)
                )
            ],
            in: directory
        )

        let attachmentFiles = try attachmentFileURLs(in: directory)
        XCTAssertEqual(attachmentFiles.count, 2)
        try FileManager.default.removeItem(at: attachmentFiles[0])

        let reservation = try XCTUnwrap(
            try HermesShareDraft.reserveNextPendingImport(from: directory)
        )
        XCTAssertEqual(reservation.sharedImport.draft, "Review what remains")
        XCTAssertEqual(reservation.sharedImport.attachments.count, 1)
        try HermesShareDraft.consume(reservation, from: directory)
    }

    func testFailedInboxPreparationDoesNotOverwriteExistingFile() throws {
        let parent = try temporaryDirectory()
        let fileURL = parent.appendingPathComponent("not-a-directory")
        let originalData = Data("keep me".utf8)
        try originalData.write(to: fileURL)

        XCTAssertThrowsError(
            try HermesShareDraft.savePendingDraft("Unsaved share", in: fileURL)
        )
        XCTAssertEqual(try Data(contentsOf: fileURL), originalData)
    }

    func testPendingImportDecodesLegacyDraftOnlyPayload() throws {
        let directory = try temporaryDirectory()
        let payloadURL = directory.appendingPathComponent(HermesShareDraft.pendingDraftFileName)
        let legacyPayload = """
        {
          "draft": "Legacy note",
          "createdAt": 1800000002
        }
        """
        try Data(legacyPayload.utf8).write(to: payloadURL)

        let sharedImport = try XCTUnwrap(try HermesShareDraft.loadPendingImport(from: directory))

        XCTAssertEqual(sharedImport.draft, "Legacy note")
        XCTAssertTrue(sharedImport.attachments.isEmpty)
    }

    func testMalformedLegacyPayloadDoesNotBlockTransactionalInbox() throws {
        let directory = try temporaryDirectory()
        try HermesShareDraft.savePendingDraft("Valid new share", in: directory)

        let legacyPayloadURL = directory.appendingPathComponent(HermesShareDraft.pendingDraftFileName)
        try Data("not json".utf8).write(to: legacyPayloadURL)
        let legacyAttachmentsURL = directory.appendingPathComponent(
            HermesShareDraft.pendingAttachmentsDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: legacyAttachmentsURL, withIntermediateDirectories: true)
        try Data("orphan".utf8).write(to: legacyAttachmentsURL.appendingPathComponent("orphan.txt"))

        let reservation = try XCTUnwrap(
            try HermesShareDraft.reserveNextPendingImport(from: directory)
        )

        XCTAssertEqual(reservation.sharedImport.draft, "Valid new share")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPayloadURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyAttachmentsURL.path))
    }

    func testEmptyPendingDraftIsNotWritten() throws {
        let directory = try temporaryDirectory()

        try HermesShareDraft.savePendingDraft(" \n ", in: directory)

        XCTAssertNil(try HermesShareDraft.loadPendingDraft(from: directory))
    }

    // MARK: - On a Hermes server (#1181)

    private let hermes = URL(string: "https://studio.example:9119")!
    private let webui = URL(string: "https://webui.example")!

    private func account(_ server: URL, _ kind: ServerKind) -> ServerAccount {
        ServerAccount(id: server.absoluteString, urlString: server.absoluteString, displayName: "", initials: "",
                      headerLogoColorHex: HeaderLogoColor.defaultHex, createdAt: Date(timeIntervalSince1970: 0),
                      updatedAt: Date(timeIntervalSince1970: 0), kind: kind)
    }

    private func reservation(_ draft: String, _ attachments: [SharedAttachmentImport] = []) -> SharedImportReservation {
        SharedImportReservation(itemID: "item", reservationID: UUID().uuidString, createdAt: Date(timeIntervalSince1970: 0),
                                sharedImport: SharedImport(draft: draft, attachments: attachments))
    }

    @MainActor
    func testTheHermesSessionsListOpensAShareAsANewSessionOnceItCan() throws {
        let connection = BotConnection(id: UUID(), name: "Host", address: hermes, username: "me", password: "secret")
        let entry = HermesSessionListEntry(server: hermes, connection: connection, profile: nil)
        let photo = SharedAttachmentImport(filename: "photo.jpg", typeIdentifier: "public.jpeg", data: Data([1, 2, 3]))
        let pdf = SharedAttachmentImport(filename: "notes.pdf", typeIdentifier: "com.adobe.pdf", data: Data([4, 5]))
        let share = reservation("  Read this  ", [photo, pdf])

        XCTAssertNil(share.hermesOpening(on: entry, listed: nil, isLive: true), "Waits for New Session's Profile")
        XCTAssertNil(share.hermesOpening(on: entry, listed: "default", isLive: false),
                     "Waits for the list's live read of the host, as a Shortcut's new session does")
        guard case .chat(let chat)? = share.hermesOpening(on: entry, listed: "default", isLive: true) else {
            return XCTFail("A share opens a new session")
        }
        XCTAssertEqual(chat.target, .new(profile: "default"))
        XCTAssertEqual(chat.server, hermes)
        XCTAssertEqual(chat.connection, connection)
        XCTAssertFalse(chat.autoStartsVoiceInput)

        guard case .chat(let filesOnly)? = reservation("", [pdf]).hermesOpening(on: entry, listed: "dev", isLive: true) else {
            return XCTFail("A file alone opens a new session")
        }
        XCTAssertEqual(filesOnly.target, .new(profile: "dev"))

        XCTAssertEqual(reservation(" \n ").hermesOpening(on: entry, listed: "default", isLive: true), .nothing,
                       "An empty share is consumed without a chat")
    }

    @MainActor
    private func newSession(_ profile: String = "default") -> (chat: HermesSessionChat, key: ChatDraftKey) {
        let connection = BotConnection(id: UUID(uuidString: "00000000-0000-0000-0000-000000001181")!, name: "Host",
                                       address: hermes, username: "me", password: "secret")
        let entry = HermesSessionListEntry(server: hermes, connection: connection, profile: nil)
        guard case .chat(let chat)? = reservation("x").hermesOpening(on: entry, listed: profile, isLive: true) else {
            preconditionFailure("A share opens a new session")
        }
        return (chat, .hermesSession(server: hermes, connectionID: connection.id, profile: profile, key: nil))
    }

    /// A store that writes to disk only on `flush`, as a share's move must.
    @MainActor
    private func drafts(_ disk: BotMemoryDrafts, _ copies: any ChatDraftAttachmentStoring) -> ChatDraftStore {
        ChatDraftStore(persistence: disk, attachmentStore: copies, debounceDuration: .seconds(3600))
    }

    @MainActor
    func testAShareIsOnDiskInItsNewSessionsDraftBeforeItIsConsumed() async throws {
        let disk = BotMemoryDrafts()
        let copies = BotAttachmentCopies()
        let (chat, key) = newSession()
        let pdf = SharedAttachmentImport(filename: "notes.pdf", typeIdentifier: "com.adobe.pdf", data: Data([4, 5]))
        let broken = SharedAttachmentImport(filename: "photo.heic", typeIdentifier: "public.heic", data: Data([1, 2, 3]))

        let failure = try await reservation("  Read this  ", [pdf, broken]).moveIntoDraft(of: chat, drafts: drafts(disk, copies))

        XCTAssertEqual(failure, .unreadable, "A file Hermes can't take is left out, and the list says why")
        // The next New Session in this Profile, even after a relaunch, restores the share from disk.
        let restored = await drafts(disk, copies).draft(for: key)
        XCTAssertEqual(restored?.text, "Read this\n")
        XCTAssertEqual(restored?.attachments.map(\.name), ["notes.pdf"])
        XCTAssertEqual(restored?.attachments.first?.mime, "application/pdf")
        let file = try XCTUnwrap(restored?.attachments.first?.file)
        let copy = try await copies.data(named: file)
        XCTAssertEqual(copy, Data([4, 5]))
    }

    @MainActor
    func testAShareCutShortLeavesTheDraftAsItWas() async throws {
        let disk = BotMemoryDrafts()
        let copies = PausingCopies()
        let store = drafts(disk, copies)
        let (chat, key) = newSession()
        let pdf = SharedAttachmentImport(filename: "notes.pdf", typeIdentifier: "com.adobe.pdf", data: Data([4, 5]))
        let saving = expectation(description: "The first file's copy is being written")
        await copies.onSave { saving.fulfill() }

        let move = Task { try await reservation("Read this", [pdf, pdf]).moveIntoDraft(of: chat, drafts: store) }
        await fulfillment(of: [saving], timeout: 5)
        move.cancel()
        await copies.resume()

        do {
            _ = try await move.value
            XCTFail("A move cut short throws, so the share is not consumed")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let draft = await store.draft(for: key)
        XCTAssertNil(draft, "The draft is unchanged")
        let onDisk = await disk.values
        XCTAssertTrue(onDisk.isEmpty)
        let kept = await copies.count
        XCTAssertEqual(kept, 0, "No copy is left behind")
    }

    @MainActor
    func testALaterShareAddsToTheUnsentOneBeforeIt() async throws {
        let disk = BotMemoryDrafts()
        let copies = BotAttachmentCopies()
        let (chat, key) = newSession()
        let a = SharedAttachmentImport(filename: "a.pdf", typeIdentifier: "com.adobe.pdf", data: Data([1]))
        let b = SharedAttachmentImport(filename: "b.txt", typeIdentifier: "public.plain-text", data: Data([2]))

        _ = try await reservation("Share A", [a]).moveIntoDraft(of: chat, drafts: drafts(disk, copies))
        // The user backs out without sending, then shares again into the same Profile.
        _ = try await reservation("Share B", [b]).moveIntoDraft(of: newSession().chat, drafts: drafts(disk, copies))

        let draft = await drafts(disk, copies).draft(for: key)
        XCTAssertEqual(draft?.text, "Share A\n\nShare B\n")
        XCTAssertEqual(draft?.attachments.map(\.name), ["a.pdf", "b.txt"])
    }

    func testAHermesServerOpensEachShareAsItArrives() {
        let servers = [account(hermes, .hermes), account(webui, .webui)]
        XCTAssertTrue(SharedImportGate.opensNext(afterRouting: false, active: webui, servers: servers))
        XCTAssertFalse(SharedImportGate.opensNext(afterRouting: true, active: webui, servers: servers),
                       "The webui list offers a later share in its Open Next banner")
        XCTAssertTrue(SharedImportGate.opensNext(afterRouting: false, active: hermes, servers: servers))
        XCTAssertTrue(SharedImportGate.opensNext(afterRouting: true, active: hermes, servers: servers),
                      "The Hermes home has no banner, so a later share opens too")
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func attachmentFileURLs(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return []
        }

        return enumerator.compactMap { element in
            guard
                let url = element as? URL,
                url.pathExtension != "json",
                (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else {
                return nil
            }
            return url
        }
    }
}

/// Draft copies whose next write waits for `resume`, so a test can cut a share's move short.
private actor PausingCopies: ChatDraftAttachmentStoring {
    private let copies = BotAttachmentCopies()
    private var saved: (() -> Void)?
    private var paused: CheckedContinuation<Void, Never>?
    private var isResumed = false
    var count: Int { get async { await copies.count } }

    func onSave(_ saved: @escaping () -> Void) { self.saved = saved }
    func resume() {
        isResumed = true
        paused?.resume()
        paused = nil
    }

    func save(data: Data, suggestedFilename: String) async throws -> String {
        saved?()
        saved = nil
        if !isResumed { await withCheckedContinuation { paused = $0 } }
        return await copies.save(data: data, suggestedFilename: suggestedFilename)
    }
    func retainedFileBytes() async throws -> [String: Int] { try await copies.retainedFileBytes() }
    func data(named fileName: String) async throws -> Data { try await copies.data(named: fileName) }
    func fileURL(named fileName: String) async throws -> URL { try await copies.fileURL(named: fileName) }
    func delete(named fileName: String) async { await copies.delete(named: fileName) }
    func sweep(keepingReferenced fileNames: Set<String>, olderThan maxAge: TimeInterval) async {}
}
