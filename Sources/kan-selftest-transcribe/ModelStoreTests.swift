import CryptoKit
import Foundation
import KanCore
import KanTestKit
import KanTranscribe

// MARK: - Stub HTTP server (URLProtocol), so download tests never touch the network

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Mode: Sendable {
        case normal
        /// Answer 200 with the whole body even when a Range is requested.
        case ignoreRange
        /// The first request drops the connection after this many bytes.
        case dropOnceAfter(Int)
        /// Send this many bytes, then hang until cancelled.
        case stallAfter(Int)
        case status(Int)
    }

    struct Route: Sendable {
        var body: Data
        var mode: Mode
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: Route] = [:]
    nonisolated(unsafe) private static var log: [(path: String, range: String?)] = []
    nonisolated(unsafe) private static var dropped: Set<String> = []

    static func reset(_ newRoutes: [String: Route]) {
        lock.withLock {
            routes = newRoutes
            log = []
            dropped = []
        }
    }

    static var requests: [(path: String, range: String?)] { lock.withLock { log } }

    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "models.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let range = request.value(forHTTPHeaderField: "Range")
        let (route, firstDrop) = Self.lock.withLock { () -> (Route?, Bool) in
            Self.log.append((url.path, range))
            let first = !Self.dropped.contains(url.path)
            if case .dropOnceAfter = Self.routes[url.path]?.mode { Self.dropped.insert(url.path) }
            return (Self.routes[url.path], first)
        }
        guard let route else { return respond(url: url, status: 404, headers: [:], body: Data()) }
        if case .status(let code) = route.mode { return respond(url: url, status: code, headers: [:], body: Data()) }

        var start = 0
        if let range, case .normal = route.mode, range.hasPrefix("bytes="), let value = Int(range.dropFirst(6).dropLast()) {
            start = value
        } else if let range, case .dropOnceAfter = route.mode, range.hasPrefix("bytes="), let value = Int(range.dropFirst(6).dropLast()) {
            start = value
        } else if let range, case .stallAfter = route.mode, range.hasPrefix("bytes="), let value = Int(range.dropFirst(6).dropLast()) {
            start = value
        }
        let total = route.body.count
        if start >= total && total > 0 {
            return respond(url: url, status: 416, headers: ["Content-Range": "bytes */\(total)"], body: Data())
        }
        var headers = ["Content-Length": "\(total - start)"]
        if start > 0 { headers["Content-Range"] = "bytes \(start)-\(total - 1)/\(total)" }
        let response = HTTPURLResponse(url: url, statusCode: start > 0 ? 206 : 200, httpVersion: "HTTP/1.1", headerFields: headers)
        guard let response else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var limit = total
        switch route.mode {
        case .dropOnceAfter(let bytes) where firstDrop: limit = min(total, start + bytes)
        case .stallAfter(let bytes): limit = min(total, start + bytes)
        default: break
        }
        var offset = start
        while offset < limit {
            let end = min(limit, offset + 16_384)
            client?.urlProtocol(self, didLoad: route.body.subdata(in: offset..<end))
            offset = end
        }
        switch route.mode {
        case .dropOnceAfter where firstDrop:
            // A real connection drops after the data already arrived; failing synchronously here would
            // make URLSession discard the undelivered data.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [self] in
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
        case .stallAfter:
            return   // hang until stopLoading
        default:
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private func respond(url: URL, status: Int, headers: [String: String], body: Data) {
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ value: Double) { lock.withLock { values.append(value) } }
    var all: [Double] { lock.withLock { values } }
}

/// A catalog whose files are tiny, so "installed" can be simulated with placeholder files.
private func tinyCatalog() -> [ModelSpec] {
    ModelCatalog.all.enumerated().map { index, spec in
        var copy = spec
        if spec.kind != .fluidAudio {
            copy.sizeBytes = Int64(16 + index)
            copy.sha256 = nil
        }
        return copy
    }
}

private func install(_ ids: [String], in store: ModelStore) throws {
    for id in ids {
        let spec = try expectNotNil(store.spec(id))
        try Data(repeating: 1, count: Int(spec.sizeBytes)).write(to: store.location(of: spec))
    }
}

func modelStoreSuite() -> TestSuite {
    let suite = TestSuite("ModelStore")
    func store(_ name: String, installed: [String]) throws -> ModelStore {
        let store = ModelStore(directory: scratchDirectory(name), catalog: tinyCatalog())
        try install(installed, in: store)
        return store
    }

    suite.test("auto prefers the best installed model per role") {
        let s = try store("resolve-1", installed: ["large-v3", "large-v3-turbo", "bengali-medium-q5_0", "silero-v6.2.0"])
        var models = s.resolveModels()
        try expectEqual([models.general?.id, models.english?.id, models.bangla?.id, models.vad?.id],
                        ["large-v3", "large-v3-turbo", "bengali-medium-q5_0", "silero-v6.2.0"])
        try install(["large-v3-q5_0", "bengali-medium-q8_0"], in: s)
        models = s.resolveModels()
        try expectEqual([models.general?.id, models.bangla?.id], ["large-v3-q5_0", "bengali-medium-q8_0"])
    }
    suite.test("english and bangla fall back to the general model") {
        let s = try store("resolve-2", installed: ["large-v3-turbo"])
        let models = s.resolveModels()
        try expectEqual([models.general?.id, models.english?.id, models.bangla?.id],
                        ["large-v3-turbo", "large-v3-turbo", "large-v3-turbo"])
        let none = try store("resolve-3", installed: [])
        try expect(none.resolveModels().general == nil && none.resolveModels().bangla == nil)
    }
    suite.test("explicit ids: used when installed, otherwise auto with a note") {
        let s = try store("resolve-4", installed: ["large-v3", "large-v3-q5_0", "bengali-medium-q8_0"])
        try expectEqual(s.resolve("large-v3", role: .general).spec?.id, "large-v3")
        let missing = s.resolve("large-v3-turbo", role: .english)
        try expectEqual(missing.spec?.id, "large-v3-q5_0")
        try expect(missing.note?.contains("not installed") == true, missing.note ?? "")
        let unknown = s.resolve("whisper-xxl", role: .bangla)
        try expectEqual(unknown.spec?.id, "bengali-medium-q8_0")
        try expect(unknown.note?.contains("Unknown") == true)
        let wrongRole = s.resolve("bengali-medium-q8_0", role: .general)
        try expectEqual(wrongRole.spec?.id, "large-v3-q5_0", "a Bangla-only model can't be the general model")
    }
    suite.test("a file with the wrong size is not installed") {
        let s = try store("size", installed: [])
        let spec = try expectNotNil(s.spec("large-v3"))
        try Data(repeating: 0, count: 3).write(to: s.location(of: spec))
        try expect(!s.isInstalled(spec))
    }
    suite.test("readiness explains what is missing and what would help") {
        var settings = KanSettings()
        let empty = try store("ready-1", installed: [])
        let nothing = empty.readiness(for: settings)
        try expect(!nothing.canTranscribe)
        try expectEqual(nothing.missing.count, 2, "\(nothing.missing)")
        let basic = try store("ready-2", installed: ["large-v3", "silero-v6.2.0"])
        let readiness = basic.readiness(for: settings)
        try expect(readiness.canTranscribe)
        try expect(readiness.recommendations.contains { $0.contains("Bangla model") }, "\(readiness.recommendations)")
        try expect(readiness.recommendations.contains { $0.contains("turbo") })
        try expect(readiness.recommendations.contains { $0.contains("speaker models") })
        try expectEqual(readiness.resolved[.general], "large-v3")
        try expectEqual(readiness.resolved[.bangla], "large-v3")
        settings.languageMode = .bangla
        let banglaOnly = try store("ready-3", installed: ["bengali-medium-q8_0", "silero-v6.2.0"])
        try expect(banglaOnly.readiness(for: settings).canTranscribe)
        settings.languageMode = .auto
        try expect(!banglaOnly.readiness(for: settings).canTranscribe)
    }
    suite.test("available models list install state and recommended defaults") {
        let s = try store("list", installed: ["large-v3-turbo"])
        let models = s.availableModels()
        try expectEqual(models.count, ModelCatalog.all.count)
        try expect(models.first { $0.id == "large-v3-turbo" }?.installed == true)
        try expectEqual(Set(models.filter(\.recommended).map(\.id)),
                        ["large-v3-q5_0", "large-v3-turbo", "bengali-medium-q8_0", "silero-v6.2.0", "fluidaudio-diarization"])
        try expect(models.allSatisfy(\.downloadable))
    }
    suite.test("delete removes the file and any partial download") {
        let s = try store("delete", installed: ["large-v3"])
        let spec = try expectNotNil(s.spec("large-v3"))
        try Data([1, 2]).write(to: s.location(of: spec).appendingPathExtension("partial"))
        try s.delete("large-v3")
        try expect(!FileManager.default.fileExists(atPath: s.location(of: spec).path))
        try expect(!FileManager.default.fileExists(atPath: s.location(of: spec).appendingPathExtension("partial").path))
        try s.delete("large-v3")   // idempotent
        try expectThrows { try s.delete("nope") }
    }
    return suite
}

func downloadSuite() -> TestSuite {
    let suite = TestSuite("ModelStore downloads")
    var generator = SeededGenerator(seed: 42)
    let payload = Data((0..<300_000).map { _ in UInt8.random(in: 0...255, using: &generator) })
    let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()

    func makeStore(_ name: String, sha: String? = nil) throws -> (ModelStore, ModelSpec) {
        let url = try expectNotNil(URL(string: "https://models.test/files/\(name).bin"))
        let spec = ModelSpec(id: "test-\(name)", displayName: "Test", detail: "", role: .general, kind: .whisper,
                             fileName: "\(name).bin", url: url, sizeBytes: Int64(payload.count), sha256: sha ?? digest)
        let store = ModelStore(directory: scratchDirectory("download-\(name)"), catalog: [spec],
                               sessionConfiguration: StubURLProtocol.configuration)
        return (store, spec)
    }

    suite.test("downloads, verifies SHA-256 and installs atomically") {
        let (store, spec) = try makeStore("full")
        StubURLProtocol.reset(["/files/full.bin": .init(body: payload, mode: .normal)])
        let progress = ProgressLog()
        try await store.download(spec.id) { progress.add($0) }
        try expectEqual(try Data(contentsOf: store.location(of: spec)), payload)
        try expect(store.isInstalled(spec))
        try expect(!FileManager.default.fileExists(atPath: store.location(of: spec).appendingPathExtension("partial").path))
        let values = progress.all
        try expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }, "monotonic")
        try expectEqual(values.last, 1)
    }
    suite.test("resumes a partial file with a Range request") {
        let (store, spec) = try makeStore("resume")
        StubURLProtocol.reset(["/files/resume.bin": .init(body: payload, mode: .normal)])
        try payload.prefix(100_000).write(to: store.location(of: spec).appendingPathExtension("partial"))
        try await store.download(spec.id) { _ in }
        try expectEqual(StubURLProtocol.requests.map(\.range), ["bytes=100000-"])
        try expectEqual(try Data(contentsOf: store.location(of: spec)), payload)
    }
    suite.test("starts over when the server ignores Range") {
        let (store, spec) = try makeStore("norange")
        StubURLProtocol.reset(["/files/norange.bin": .init(body: payload, mode: .ignoreRange)])
        try payload.prefix(50_000).write(to: store.location(of: spec).appendingPathExtension("partial"))
        try await store.download(spec.id) { _ in }
        try expectEqual(try Data(contentsOf: store.location(of: spec)), payload)
    }
    suite.test("retries a dropped connection and resumes where it stopped") {
        let (store, spec) = try makeStore("drop")
        StubURLProtocol.reset(["/files/drop.bin": .init(body: payload, mode: .dropOnceAfter(163_840))])
        try await store.download(spec.id) { _ in }
        let requests = StubURLProtocol.requests
        try expectEqual(requests.count, 2)
        try expect(requests[0].range == nil)
        try expectEqual(requests[1].range, "bytes=163840-")
        try expectEqual(try Data(contentsOf: store.location(of: spec)), payload)
    }
    suite.test("a checksum mismatch deletes the download") {
        let (store, spec) = try makeStore("badsum", sha: String(repeating: "0", count: 64))
        StubURLProtocol.reset(["/files/badsum.bin": .init(body: payload, mode: .normal)])
        do {
            try await store.download(spec.id) { _ in }
            throw fail("expected a checksum error")
        } catch ModelStoreError.checksumMismatch {
        }
        try expect(!FileManager.default.fileExists(atPath: store.location(of: spec).path))
        try expect(!FileManager.default.fileExists(atPath: store.location(of: spec).appendingPathExtension("partial").path))
    }
    suite.test("HTTP errors are reported") {
        let (store, spec) = try makeStore("missing")
        StubURLProtocol.reset(["/files/missing.bin": .init(body: payload, mode: .status(404))])
        do {
            try await store.download(spec.id) { _ in }
            throw fail("expected an HTTP error")
        } catch ModelStoreError.httpStatus(let code) {
            try expectEqual(code, 404)
        }
    }
    suite.test("cancelling keeps the partial file; a second download of the same model is refused") {
        let (store, spec) = try makeStore("stall")
        StubURLProtocol.reset(["/files/stall.bin": .init(body: payload, mode: .stallAfter(65_536))])
        let started = ProgressLog()
        let task = Task { try await store.download(spec.id) { started.add($0) } }
        for _ in 0..<200 where started.all.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        try expect(!started.all.isEmpty, "the download should have started")
        do {
            try await store.download(spec.id) { _ in }
            throw fail("expected alreadyDownloading")
        } catch ModelStoreError.alreadyDownloading {
        }
        task.cancel()
        do {
            try await task.value
            throw fail("expected cancellation")
        } catch is CancellationError {
        }
        let partial = store.location(of: spec).appendingPathExtension("partial")
        let attributes = try FileManager.default.attributesOfItem(atPath: partial.path)
        try expectEqual((attributes[.size] as? NSNumber)?.intValue, 65_536)
    }
    suite.test("unknown models can't be downloaded") {
        let (store, _) = try makeStore("unknown")
        do {
            try await store.download("nope") { _ in }
            throw fail("expected unknownModel")
        } catch ModelStoreError.unknownModel {
        }
    }
    return suite
}
