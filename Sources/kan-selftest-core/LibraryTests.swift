import Foundation
import KanCore
import KanTestKit

func libraryTests() -> TestSuite {
    let suite = TestSuite("Library")
    let fm = FileManager.default

    suite.test("save writes the JSON + Markdown pair with valid front matter") {
        let lib = TestLibrary("lib-save")
        let record = Fixture.record(title: "Advisor meeting: augmentation idea", folder: "Research/Thesis",
                                    tags: ["research", "thesis"], starred: true,
                                    segments: [Fixture.segment(0, 5, 9, "me", "So I was thinking…"),
                                               Fixture.segment(1, 21, 25, "s1", "That's interesting…")],
                                    languages: ["en", "bn"])
        let files = try lib.store.save(record)
        let base = "Research/Thesis/2026-11-14 1000 Advisor meeting - augmentation idea"
        try expectEqual(lib.files(), ["AGENTS.md", base + ".json", base + ".md", "index.jsonl", "index.md"])
        try expectEqual(files.json.lastPathComponent, "2026-11-14 1000 Advisor meeting - augmentation idea.json")
        let decoded = try JSONDecoder.kan.decode(CallRecord.self, from: Data(contentsOf: files.json))
        try expectEqual(decoded.id, record.id)
        try expectEqual(decoded.kind, "kan.call")
        try expectEqual(decoded.title, record.title)
        try expectEqual(decoded.folder, "Research/Thesis")
        try expectEqual(decoded.segments, record.segments)
        try expect(decoded.updatedAt.timeIntervalSince(record.updatedAt) > -0.001)   // JSON keeps milliseconds
        let md = try String(contentsOf: files.markdown, encoding: .utf8)
        let fm = try MiniYAML.dictionary(md)
        try expectEqual(fm["kan_id"], .plain(record.id.rawValue))
        try expectEqual(fm["title"], .quoted("Advisor meeting: augmentation idea"))
        try expectEqual(fm["date"], .plain("2026-11-14T10:00:12-05:00"))
        try expectEqual(fm["end"], .plain("2026-11-14T10:42:25-05:00"))
        try expectEqual(fm["duration"], .quoted("00:42:13"))
        try expectEqual(fm["app"], .plain("Zoom"))
        try expectEqual(fm["platform"], .plain("zoom"))
        try expectEqual(fm["folder"], .quoted("Research/Thesis"))
        try expectEqual(fm["tags"], .list(["research", "thesis"]))
        try expectEqual(fm["people"], .list(["Nahian", "Prof. Rahman"]))
        try expectEqual(fm["languages"], .list(["en", "bn"]))
        try expectEqual(fm["starred"], .plain("true"))
        try expectEqual(fm["status"], .plain("ready"))
        try expect(md.contains("**Prof. Rahman** [00:00:21]\nThat's interesting…"), md)
    }

    suite.test("file names use the call's own time zone and a sanitized title") {
        let lib = TestLibrary("lib-names")
        let dhaka = Fixture.record(title: "ঢাকা সকাল", start: "2026-11-14T15:00:12Z", timeZone: "Asia/Dhaka")
        try expectEqual(try lib.store.save(dhaka).json.lastPathComponent, "2026-11-14 2100 ঢাকা সকাল.json")
        try expectEqual(LibraryStore.fileBaseName(for: dhaka), "2026-11-14 2100 ঢাকা সকাল")
        let nasty = Fixture.record(title: "Q&A: what's next? / plan <v2> \"draft\"\tnow...")
        try expectEqual(try lib.store.save(nasty).json.deletingPathExtension().lastPathComponent,
                        "2026-11-14 1000 Q&A - what's next - plan v2 'draft' now")
        try expectEqual(try lib.store.record(nasty.id).title, "Q&A: what's next? / plan <v2> \"draft\" now...")
        let long = Fixture.record(title: String(repeating: "augmentation ", count: 20))
        let longName = try lib.store.save(long).json.deletingPathExtension().lastPathComponent
        try expect(longName.count <= 16 + 90 && longName.hasSuffix("augmentation"), longName)
        let bangla = Fixture.record(title: String(repeating: "স্পিচ রিকগনিশন ", count: 30))
        let banglaName = try lib.store.save(bangla).json.lastPathComponent
        try expect(banglaName.utf8.count <= 255, "\(banglaName.utf8.count) bytes")
        try expect(!banglaName.contains("  "), banglaName)
        let slashes = Fixture.record(title: "///")
        try expectEqual(try lib.store.save(slashes).json.lastPathComponent, "2026-11-14 1000 Untitled call.json")
        let empty = Fixture.record(title: "  ", speakers: [])
        try lib.store.save(empty)
        try expectEqual(try lib.store.record(empty.id).title, "Zoom call")     // empty titles become the suggestion
        let badZone = Fixture.record(title: "Somewhere", timeZone: "Mars/Olympus_Mons")
        try lib.store.save(badZone)                                             // falls back to the current zone
        try expect(lib.store.files(for: badZone.id) != nil)
    }

    suite.test("reload in a fresh store finds every call, newest first") {
        let lib = TestLibrary("lib-reload")
        let a = Fixture.record(title: "Oldest", start: "2026-01-01T09:00:00-05:00")
        let b = Fixture.record(title: "Middle", folder: "Research", start: "2026-06-01T09:00:00-04:00",
                               segments: [Fixture.segment(0, 0, 1, "me", "hello")])
        let c = Fixture.record(title: "Newest", folder: "Research/Thesis", start: "2026-10-30T09:00:00-04:00")
        for r in [b, a, c] { try lib.store.save(r) }
        let other = lib.reopened()
        try expectEqual(try other.reload().map(\.title), ["Newest", "Middle", "Oldest"])
        try expectEqual(other.summaries().map(\.id), [c.id, b.id, a.id])
        let loaded = try other.record(b.id)
        try expectEqual(loaded.title, "Middle")
        try expectEqual(loaded.folder, "Research")
        try expectEqual(loaded.segments, b.segments)
        try expectEqual(loaded.speakers, b.speakers)
        try expect(other.contains(a.id))
        try expect(!other.contains(CallID.generate()))
        try expectEqual(other.files(for: c.id)?.json.lastPathComponent, "2026-10-30 0900 Newest.json")
        try expectEqual(other.summary(c.id)?.markdownPath, "Research/Thesis/2026-10-30 0900 Newest.md")
        try expectEqual(other.summary(c.id)?.jsonPath, "Research/Thesis/2026-10-30 0900 Newest.json")
    }

    suite.test("a title change renames both files and leaves nothing stale") {
        let lib = TestLibrary("lib-rename")
        let record = Fixture.record(title: "Zoom call")
        try lib.store.save(record)
        try lib.store.update(record.id) { $0.title = "Thesis chat" }
        try expectEqual(lib.files().filter { $0.hasPrefix("Inbox/") },
                        ["Inbox/2026-11-14 1000 Thesis chat.json", "Inbox/2026-11-14 1000 Thesis chat.md"])
        // A case-only change (one file on case-insensitive APFS) must neither lose nor duplicate it.
        try lib.store.update(record.id) { $0.title = "THESIS chat" }
        try expectEqual(lib.files().filter { $0.hasPrefix("Inbox/") },
                        ["Inbox/2026-11-14 1000 THESIS chat.json", "Inbox/2026-11-14 1000 THESIS chat.md"])
        try expectEqual(try lib.store.record(record.id).title, "THESIS chat")
        try expectEqual(try lib.reopened().reload().map(\.title), ["THESIS chat"])
        try expect(lib.read("Inbox/2026-11-14 1000 THESIS chat.md").contains("# THESIS chat"))
    }

    suite.test("moving between folders, nested ones included, moves both files") {
        let lib = TestLibrary("lib-move")
        let record = Fixture.record(title: "Sync")
        try lib.store.save(record)
        for folder in ["Research", "Research/Thesis/Deep", "", "Projects"] {
            try lib.store.update(record.id) { $0.folder = folder }
            let directory = folder.isEmpty ? "Inbox" : folder
            let calls = lib.files().filter { ($0.hasSuffix(".json") || $0.hasSuffix(".md")) && $0.contains("/") }
            try expectEqual(calls, ["\(directory)/2026-11-14 1000 Sync.json", "\(directory)/2026-11-14 1000 Sync.md"], folder)
            try expectEqual(try lib.store.record(record.id).folder, folder)
            try expectEqual(lib.store.summary(record.id)?.folder, folder)
        }
        try expectEqual(lib.store.folders().map(\.name), ["", "Projects", "Research", "Research/Thesis", "Research/Thesis/Deep"])
        try expectEqual(lib.store.folders().map(\.count), [0, 1, 0, 0, 0])
    }

    suite.test("collisions get (2), (3); records keep their names; user files are never overwritten") {
        let lib = TestLibrary("lib-collide")
        let a = Fixture.record(title: "Standup"), b = Fixture.record(title: "Standup"), c = Fixture.record(title: "Standup")
        try expectEqual(try lib.store.save(a).json.lastPathComponent, "2026-11-14 1000 Standup.json")
        try expectEqual(try lib.store.save(b).json.lastPathComponent, "2026-11-14 1000 Standup (2).json")
        try expectEqual(try lib.store.save(c).json.lastPathComponent, "2026-11-14 1000 Standup (3).json")
        try expectEqual(try lib.store.save(b).json.lastPathComponent, "2026-11-14 1000 Standup (2).json")
        try lib.store.delete(a.id, deleteAudio: false)
        try lib.store.update(c.id) { $0.notes = "still number three" }
        try expectEqual(lib.store.files(for: c.id)?.json.lastPathComponent, "2026-11-14 1000 Standup (3).json")
        let d = Fixture.record(title: "Standup")
        try expectEqual(try lib.store.save(d).json.lastPathComponent, "2026-11-14 1000 Standup.json")
        let userFile = lib.url("Inbox/2026-11-14 1000 Retro.md")
        try Data("my own notes".utf8).write(to: userFile)
        let e = Fixture.record(title: "Retro")
        try expectEqual(try lib.store.save(e).markdown.lastPathComponent, "2026-11-14 1000 Retro (2).md")
        try expectEqual(try String(contentsOf: userFile, encoding: .utf8), "my own notes")
        try expectEqual(try lib.reopened().reload().count, 4)
    }

    suite.test("delete removes the pair, and the audio only when asked") {
        let lib = TestLibrary("lib-delete")
        let keep = Fixture.record(title: "Keep audio"), drop = Fixture.record(title: "Drop audio")
        for r in [keep, drop] {
            try lib.store.save(r)
            try fm.createDirectory(at: lib.callDirectory(r.id), withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: lib.callDirectory(r.id).appendingPathComponent("me.wav"))
        }
        try lib.store.delete(keep.id, deleteAudio: false)
        try lib.store.delete(drop.id, deleteAudio: true)
        try expect(fm.fileExists(atPath: lib.callDirectory(keep.id).appendingPathComponent("me.wav").path))
        try expect(!fm.fileExists(atPath: lib.callDirectory(drop.id).path))
        try expectEqual(lib.files().filter { $0.hasPrefix("Inbox/") }, [])
        try expectEqual(lib.store.summaries().count, 0)
        try expectThrows { _ = try lib.store.record(keep.id) }
        try expectThrows { try lib.store.delete(keep.id, deleteAudio: true) }
        try expectEqual(lib.read("index.jsonl"), "")
        try expect(lib.read("index.md").contains("_No calls yet._"))
        try expectEqual(lib.store.callDataDirectory(for: keep.id), lib.callDirectory(keep.id))
    }

    suite.test("corrupt and foreign files are skipped and never touched") {
        let lib = TestLibrary("lib-corrupt")
        let good = Fixture.record(title: "Good call")
        try lib.store.save(good)
        try Data(#"{"kind": "kan.call", "id": "01ABC", "title": 5"#.utf8).write(to: lib.url("Inbox/2026-11-15 0900 Broken.json"))
        try Data(#"{"kind": "kan.call", "id": "01ABC"}"#.utf8).write(to: lib.url("Inbox/2026-11-15 1000 Half.json"))
        try Data("not json at all".utf8).write(to: lib.url("Inbox/notes.json"))
        try fm.createDirectory(at: lib.url("Research"), withIntermediateDirectories: true)
        try Data(#"{"rows": [1, 2, 3]}"#.utf8).write(to: lib.url("Research/dataset.json"))
        try fm.createDirectory(at: lib.url(".obsidian"), withIntermediateDirectories: true)
        try fm.copyItem(at: try expectNotNil(lib.store.files(for: good.id)).json, to: lib.url(".obsidian/copy.json"))
        let before = lib.files()
        let store = lib.reopened()
        try expectEqual(try store.reload().map(\.id), [good.id])
        try expectEqual(lib.files(), before)                    // nothing deleted, moved or rewritten
        try expect(store.folders().map(\.name).contains("Research"))
        try expect(!store.folders().map(\.name).contains(".obsidian"))
        try store.save(try store.record(good.id))               // writing still works around the junk
        try expectEqual(lib.files().filter { $0.hasPrefix("Inbox/") }.count, 5)
    }

    suite.test("the folder follows the files when they are moved outside Kan") {
        let lib = TestLibrary("lib-location")
        let record = Fixture.record(title: "Moved in Finder")
        let files = try lib.store.save(record)
        let target = lib.url("Archive/2025")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        for url in [files.json, files.markdown] {
            try fm.moveItem(at: url, to: target.appendingPathComponent(url.lastPathComponent))
        }
        let store = lib.reopened()
        try store.reload()
        try expectEqual(store.summary(record.id)?.folder, "Archive/2025")
        try expectEqual(try store.record(record.id).folder, "Archive/2025")
        try store.update(record.id) { $0.tags = ["old"] }
        let moved = target.appendingPathComponent(files.json.lastPathComponent)
        let onDisk = try JSONDecoder.kan.decode(CallRecord.self, from: Data(contentsOf: moved))
        try expectEqual(onDisk.folder, "Archive/2025")
        try expectEqual(onDisk.tags, ["old"])
        try expect(!fm.fileExists(atPath: files.json.path))
    }

    suite.test("folders, tags and people with counts") {
        let lib = TestLibrary("lib-counts")
        func speakers(_ names: String...) -> [Speaker] {
            [Speaker(id: "me", name: "Nahian", isMe: true)]
                + names.enumerated().map { Speaker(id: "s\($0.offset + 1)", name: $0.element, isMe: false) }
        }
        try lib.store.save(Fixture.record(title: "A", tags: ["research", "thesis"], speakers: speakers("Rahim", "Speaker 2")))
        try lib.store.save(Fixture.record(title: "B", folder: "Research", tags: ["Research"], speakers: speakers("rahim", "Karim")))
        try lib.store.save(Fixture.record(title: "C", folder: "Research/Thesis", tags: ["#thesis", "ideas"],
                                          speakers: speakers("Me", "Speaker 1")))
        try lib.store.createFolder("Empty")
        let folders = lib.store.folders()
        try expectEqual(folders.map(\.name), ["", "Empty", "Research", "Research/Thesis"])
        try expectEqual(folders.map(\.count), [1, 0, 1, 1])
        let tags = lib.store.tags()
        try expectEqual(tags.map(\.name), ["Research", "thesis", "ideas"])
        try expectEqual(tags.map(\.count), [2, 2, 1])
        let people = lib.store.people()
        try expectEqual(people.map(\.name), ["Rahim", "Karim"])
        try expectEqual(people.map(\.count), [2, 1])
    }

    suite.test("recordedApps() lists each app's bundle id from the index, without reading a call") {
        let lib = TestLibrary("lib-apps")
        func record(_ app: String, _ bundleID: String?, _ start: String) -> CallRecord {
            var r = Fixture.record(title: app, start: start, app: app, platform: .other)
            r.source.bundleID = bundleID
            return r
        }
        let calls = [record("zoom.us", "us.zoom.xos", "2026-11-10T10:00:00-05:00"),
                     record("Lumen", "com.example.lumen", "2026-11-11T10:00:00-05:00"),
                     record("Lumen Browser", "com.example.lumen", "2026-11-12T10:00:00-05:00"),
                     record("Old notes", nil, "2026-11-13T10:00:00-05:00")]
        for call in calls { try lib.store.save(call) }
        // Unreadable files on disk change nothing: the answer comes from the index.
        for call in calls {
            let json = try expectNotNil(lib.store.files(for: call.id)).json
            try Data("{ not json".utf8).write(to: json)
        }
        try expectEqual(lib.store.recordedApps(), ["us.zoom.xos": "zoom.us", "com.example.lumen": "Lumen Browser"],
                        "the newest call's app name; calls without a bundle id are left out")
        try expectEqual(lib.reopened().recordedApps(), [:], "a fresh store skips the unreadable files")
    }

    suite.test("folder names are sanitized") {
        let cases: [(String, String?)] = [
            ("", ""), ("Inbox", ""), ("inbox", ""), (" Research / Thesis ", "Research/Thesis"), ("a//b/", "a/b"),
            ("/lead", "lead"), (".hidden", "hidden"), ("..", nil), ("a/../b", nil), ("./x", nil), ("index.md", nil),
            ("AGENTS.md", nil), ("Index.JSONL", nil), ("x:y", "x-y"), ("Inbox/Sub", "Inbox/Sub"), ("inbox/sub", "Inbox/sub"),
            ("গবেষণা/থিসিস", "গবেষণা/থিসিস"), ("tab\tname", "tab name"), ("what?", "what"), ("???", nil),
            ("a/???/b", nil), ("back\\slash", "back-slash"),
        ]
        for (input, expected) in cases {
            try expectEqual(LibraryStore.sanitizeFolder(input), expected, "sanitizeFolder(\(input.debugDescription))")
        }
        let lib = TestLibrary("lib-folder-names")
        try expectThrows { try lib.store.createFolder("../evil") }
        try expectThrows { try lib.store.save(Fixture.record(folder: "..")) }
        try lib.store.createFolder("Ideas/Bangla ASR")
        try expect(fm.fileExists(atPath: lib.url("Ideas/Bangla ASR").path))
        try expectEqual(lib.store.folders().map(\.name), ["", "Ideas", "Ideas/Bangla ASR"])
        try expect(!fm.fileExists(atPath: lib.base.appendingPathComponent("evil").path))
        // A differently-cased folder name reuses the existing directory's spelling.
        let r = Fixture.record(title: "Cased", folder: "ideas/bangla asr")
        try lib.store.save(r)
        try expectEqual(lib.store.summary(r.id)?.folder, "Ideas/Bangla ASR")
        try expectEqual(lib.store.directoryURL(forFolder: "")?.lastPathComponent, "Inbox")
        try expectEqual(lib.store.directoryURL(forFolder: ".."), nil)
    }

    suite.test("renameFolder moves the directory and rewrites every call in it, nested too") {
        let lib = TestLibrary("lib-rename-folder")
        let top = Fixture.record(title: "Top", folder: "Research")
        let nested = Fixture.record(title: "Nested", folder: "Research/Thesis")
        let outside = Fixture.record(title: "Outside", folder: "Research2")
        for r in [top, nested, outside] { try lib.store.save(r) }
        try Data("attachment".utf8).write(to: lib.url("Research/figure.png"))
        let changes = Locked<[LibraryChange]>([])
        lib.store.onChange = { change in changes.mutate { $0.append(change) } }
        try lib.store.renameFolder("Research", to: "Projects/Research")
        try expectEqual(changes.current, [.reloaded])
        try expect(!fm.fileExists(atPath: lib.url("Research").path))
        try expect(fm.fileExists(atPath: lib.url("Projects/Research/figure.png").path))
        for (record, folder) in [(top, "Projects/Research"), (nested, "Projects/Research/Thesis"), (outside, "Research2")] {
            let files = try expectNotNil(lib.store.files(for: record.id))
            try expectEqual(files.json.deletingLastPathComponent().resolvingSymlinksInPath().path,
                            lib.url(folder).resolvingSymlinksInPath().path)
            let onDisk = try JSONDecoder.kan.decode(CallRecord.self, from: Data(contentsOf: files.json))
            try expectEqual(onDisk.folder, folder)
            let frontMatter = try MiniYAML.dictionary(try String(contentsOf: files.markdown, encoding: .utf8))
            try expectEqual(frontMatter["folder"], .quoted(folder))
        }
        try expectEqual(lib.store.folders().map(\.name),
                        ["", "Projects", "Projects/Research", "Projects/Research/Thesis", "Research2"])
        try expectEqual(try lib.reopened().reload().count, 3)
        try checkIndexes(lib)

        try lib.store.renameFolder("Research2", to: "research2")         // case only
        try expect(lib.files().contains("research2/2026-11-14 1000 Outside.json"), "\(lib.files())")
        try expectEqual(lib.store.summary(outside.id)?.folder, "research2")

        try expectThrows { try lib.store.renameFolder("", to: "X") }
        try expectThrows { try lib.store.renameFolder("Projects", to: "Projects/Inner") }
        try expectThrows { try lib.store.renameFolder("Projects", to: "research2") }
        try expectThrows { try lib.store.renameFolder("Nope", to: "Other") }
        try expectThrows { try lib.store.renameFolder("Projects", to: "..") }
    }

    suite.test("deleteFolder moves its calls to the Inbox and keeps other files") {
        let lib = TestLibrary("lib-delete-folder")
        let a = Fixture.record(title: "In folder", folder: "Old/Sub")
        try lib.store.save(a)
        try lib.store.createFolder("Old/Empty")
        try lib.store.createFolder("Gone")
        try Data("keep me".utf8).write(to: lib.url("Old/readme.txt"))
        try lib.store.deleteFolder("Old")
        try lib.store.deleteFolder("Gone")
        try expectEqual(lib.store.summary(a.id)?.folder, "")
        try expect(lib.files().contains("Inbox/2026-11-14 1000 In folder.json"))
        try expect(fm.fileExists(atPath: lib.url("Old/readme.txt").path))
        try expect(!fm.fileExists(atPath: lib.url("Old/Sub").path))
        try expect(!fm.fileExists(atPath: lib.url("Old/Empty").path))
        try expect(!fm.fileExists(atPath: lib.url("Gone").path))
        try expectEqual(lib.store.folders().map(\.name), ["", "Old"])
        try expectThrows { try lib.store.deleteFolder("Missing") }
        try expectThrows { try lib.store.deleteFolder("") }
    }

    suite.test("index.md, index.jsonl and AGENTS.md are correct after every save and delete") {
        let lib = TestLibrary("lib-index")
        var records: [CallRecord] = []
        for (i, title) in ["Alpha | pipes", "Beta [draft]", "বাংলা আলোচনা"].enumerated() {
            let r = Fixture.record(title: title, folder: i == 1 ? "Research" : "", start: "2026-11-1\(i)T10:00:00-05:00",
                                   tags: ["t\(i)"], starred: i == 2)
            try lib.store.save(r)
            records.append(r)
            try checkIndexes(lib)
        }
        try lib.store.update(records[0].id) { $0.title = "Alpha renamed" }
        try checkIndexes(lib)
        try lib.store.delete(records[1].id, deleteAudio: false)
        try checkIndexes(lib)
        try expect(lib.read("index.md").contains("★ [বাংলা আলোচনা]"))
        let agents = lib.read("AGENTS.md")
        for phrase in ["kan-agents-guide-version: \(AgentsGuide.version)", "isMe", "kan mcp", "read-only", "Bangla",
                       "ISO-8601", "seconds from the start of the call", "kan search", "kan export", "kan show", "kan list",
                       "Bengali script", "index.jsonl", "speakerID", "echoSuspect", "kan_id"] {
            try expect(agents.contains(phrase), "AGENTS.md lacks \(phrase)")
        }
        // Explicit rewrite produces identical files.
        let before = (lib.read("index.md"), lib.read("index.jsonl"))
        try lib.store.writeIndexes()
        try expectEqual(lib.read("index.md"), before.0)
        try expectEqual(lib.read("index.jsonl"), before.1)
    }

    suite.test("AGENTS.md is rewritten only when missing or outdated") {
        let lib = TestLibrary("lib-agents")
        try fm.createDirectory(at: lib.root, withIntermediateDirectories: true)
        let url = lib.url("AGENTS.md")
        try Data("<!-- kan-agents-guide-version: 0 -->\nold".utf8).write(to: url)
        try lib.store.save(Fixture.record(title: "One"))
        try expect(lib.read("AGENTS.md").contains("kan-agents-guide-version: \(AgentsGuide.version) -->"))
        try Data("<!-- kan-agents-guide-version: 999 -->\nfuture".utf8).write(to: url)
        try lib.store.save(Fixture.record(title: "Two"))
        try expect(lib.read("AGENTS.md").hasSuffix("future"))
        try Data("# My own agent notes".utf8).write(to: url)
        try lib.store.writeIndexes()
        try expectEqual(lib.read("AGENTS.md"), "# My own agent notes")
        try fm.removeItem(at: url)
        try lib.store.writeIndexes()
        try expectEqual(AgentsGuide.embeddedVersion(in: lib.read("AGENTS.md")), AgentsGuide.version)
    }

    suite.test("concurrent update() from many threads loses nothing") {
        let lib = TestLibrary("lib-concurrent")
        let record = Fixture.record(title: "Busy")
        try lib.store.save(record)
        let errors = Locked<[String]>([])
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            do {
                try lib.store.update(record.id) { $0.tags.append("tag\(i)") }
                _ = lib.store.search(SearchQuery(text: "busy"))
                _ = lib.store.summaries()
                _ = lib.store.folders()
                if i % 8 == 0 { try lib.store.update(record.id) { $0.notes += "n\(i) " } }
            } catch {
                errors.mutate { $0.append("\(error)") }
            }
        }
        try expectEqual(errors.current, [])
        let final = try lib.reopened().record(record.id)
        try expectEqual(Set(final.tags), Set((0..<64).map { "tag\($0)" }))
        try expectEqual(final.notes.split(separator: " ").count, 8)
        try checkIndexes(lib)
    }

    suite.test("onChange reports saves, deletes and reloads") {
        let lib = TestLibrary("lib-onchange")
        let changes = Locked<[LibraryChange]>([])
        lib.store.onChange = { change in changes.mutate { $0.append(change) } }
        let r = Fixture.record(title: "Watch me")
        try lib.store.save(r)
        try lib.store.update(r.id) { $0.starred = true }
        try lib.store.delete(r.id, deleteAudio: false)
        try lib.store.reload()
        try lib.store.createFolder("New")
        try expectEqual(changes.current, [.saved(r.id), .saved(r.id), .deleted(r.id), .reloaded, .reloaded])
    }

    suite.test("edits made outside Kan are picked up and update() keeps them") {
        let lib = TestLibrary("lib-external")
        let r = Fixture.record(title: "Original")
        let files = try lib.store.save(r)
        var edited = try JSONDecoder.kan.decode(CallRecord.self, from: Data(contentsOf: files.json))
        edited.notes = "edited in a text editor"
        try JSONEncoder.kanPretty.encode(edited).write(to: files.json)
        try expectEqual(try lib.store.record(r.id).notes, "edited in a text editor")
        try lib.store.update(r.id) { $0.tags = ["kept"] }
        let after = try lib.store.record(r.id)
        try expectEqual(after.notes, "edited in a text editor")
        try expectEqual(after.tags, ["kept"])
        try expectEqual(lib.store.search(SearchQuery(text: "text editor")).first?.field, .notes)
        try fm.removeItem(at: files.json)                     // deleted outside Kan
        try expectThrows { try lib.store.update(r.id) { $0.notes = "too late" } }
        try expect(!lib.store.contains(r.id))
    }

    suite.test("reconcile() re-renders Markdown for JSON edited outside Kan, and missing Markdown") {
        let lib = TestLibrary("lib-reconcile")
        let edited = Fixture.record(title: "Agent edits me", speakers: Fixture.speakers(others: ["Speaker 1"]))
        let untouched = Fixture.record(title: "Leave me")
        let lost = Fixture.record(title: "Lost markdown")
        let files = try lib.store.save(edited)
        try lib.store.save(untouched)
        let lostFiles = try lib.store.save(lost)
        try expectEqual(try lib.store.reconcile(), [])                       // nothing changed yet
        var json = try JSONDecoder.kan.decode(CallRecord.self, from: Data(contentsOf: files.json))
        json.speakers[1].name = "Rahim"                                      // what an agent might do
        json.speakers[1].nameSource = .user
        try JSONEncoder.kanPretty.encode(json).write(to: files.json)
        try fm.removeItem(at: lostFiles.markdown)
        let untouchedStamp = try fm.attributesOfItem(atPath: try expectNotNil(lib.store.files(for: untouched.id)).markdown.path)[.modificationDate] as? Date
        try expectEqual(Set(try lib.store.reconcile()), [edited.id, lost.id])
        try expect(try String(contentsOf: files.markdown, encoding: .utf8).contains("people: [\"Nahian\", \"Rahim\"]"))
        try expect(fm.fileExists(atPath: lostFiles.markdown.path))
        try expectEqual(try fm.attributesOfItem(atPath: try expectNotNil(lib.store.files(for: untouched.id)).markdown.path)[.modificationDate] as? Date,
                        untouchedStamp)
        try expectEqual(lib.store.people().map(\.name), ["Prof. Rahman", "Rahim"])
        try expectEqual(try lib.store.reconcile(), [])
        try checkIndexes(lib)
    }

    suite.test("update() can't change the id; unknown ids throw") {
        let lib = TestLibrary("lib-update-id")
        let r = Fixture.record(title: "Stable")
        try lib.store.save(r)
        try expectThrows { try lib.store.update(r.id) { $0.id = CallID.generate() } }
        try expectThrows { try lib.store.update(CallID.generate()) { $0.title = "x" } }
        try expectEqual(try lib.store.record(r.id).title, "Stable")
    }

    suite.test("text is stored NFC and tags are cleaned") {
        let lib = TestLibrary("lib-nfc")
        let nfd = "কোথায়".decomposedStringWithCanonicalMapping
        try expect(!nfd.unicodeScalars.elementsEqual(nfd.nfc.unicodeScalars), "test text must differ in NFD")
        var r = Fixture.record(title: nfd, tags: ["#research", "Research", " thesis ", "", "#"],
                               segments: [Fixture.segment(0, 0, 1, "s1", nfd, language: "bn")])
        r.notes = nfd
        let files = try lib.store.save(r)
        let stored = try JSONDecoder.kan.decode(CallRecord.self, from: Data(contentsOf: files.json))
        try expect(stored.title.unicodeScalars.elementsEqual(nfd.nfc.unicodeScalars))
        try expect(stored.segments[0].text.unicodeScalars.elementsEqual(nfd.nfc.unicodeScalars))
        try expect(stored.notes.unicodeScalars.elementsEqual(nfd.nfc.unicodeScalars))
        try expectEqual(stored.tags, ["research", "thesis"])
    }

    suite.test("read-only use loads lazily and writes nothing") {
        let lib = TestLibrary("lib-readonly")
        try lib.store.save(Fixture.record(title: "Readable"))
        try fm.removeItem(at: lib.url("AGENTS.md"))
        let before = lib.files()
        let stamp = try fm.attributesOfItem(atPath: lib.url("index.md").path)[.modificationDate] as? Date
        let reader = lib.reopened()
        try expectEqual(reader.summaries().map(\.title), ["Readable"])         // no reload() needed
        _ = reader.search(SearchQuery(text: "readable"))
        _ = reader.folders()
        _ = reader.tags()
        _ = reader.people()
        _ = try reader.record(try expectNotNil(reader.summaries().first).id)
        try expectEqual(lib.files(), before)
        try expectEqual(try fm.attributesOfItem(atPath: lib.url("index.md").path)[.modificationDate] as? Date, stamp)
        // A library folder that doesn't exist yet is simply empty.
        let missing = LibraryStore(root: lib.base.appendingPathComponent("Nowhere"))
        try expectEqual(try missing.reload().count, 0)
        try expect(!fm.fileExists(atPath: lib.base.appendingPathComponent("Nowhere").path))
    }

    suite.test("call JSONs whose id isn't a ULID are skipped, so deleting a call can't escape its folder") {
        let lib = TestLibrary("lib-bad-ids")
        let good = Fixture.record(title: "Good")
        let goodFiles = try lib.store.save(good)
        let goodAudio = lib.callDirectory(good.id).appendingPathComponent("me.m4a")
        try fm.createDirectory(at: lib.callDirectory(good.id), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: goodAudio)
        let template = try String(contentsOf: goodFiles.json, encoding: .utf8)
        try expect(template.contains("\"\(good.id.rawValue)\""))
        for (i, bad) in ["", ".", "..", "../victim", "../../..", "01JD3Q8Z6M7K2V9R4T5N8P1XQ/", "01JD3Q8Z6M7K2V9R4T5N8P1XQAB"].enumerated() {
            let json = template.replacingOccurrences(of: "\"\(good.id.rawValue)\"", with: "\"\(bad)\"")
            try Data(json.utf8).write(to: lib.url("Inbox/2026-11-15 090\(i) Odd \(i).json"))
        }
        // An id in lower case is still that ULID.
        let lower = Fixture.record(title: "Lower case")
        let lowerFiles = try lib.store.save(lower)
        let lowered = try String(contentsOf: lowerFiles.json, encoding: .utf8)
            .replacingOccurrences(of: "\"\(lower.id.rawValue)\"", with: "\"\(lower.id.rawValue.lowercased())\"")
        try Data(lowered.utf8).write(to: lowerFiles.json)

        let store = lib.reopened()
        try expectEqual(Set(try store.reload().map(\.id)), [good.id, lower.id])
        try expectEqual(try store.record(lower.id).id.rawValue, lower.id.rawValue)
        try expectThrows { try store.save(Fixture.record(id: CallID(rawValue: "../victim"), title: "Escape")) }
        try expectThrows { try store.delete(CallID(rawValue: ".."), deleteAudio: true) }
        try expectThrows { try store.delete(CallID(rawValue: ""), deleteAudio: true) }
        try expect(fm.fileExists(atPath: goodAudio.path), "another call's audio was deleted")
        try expect(fm.fileExists(atPath: lib.calls.path))
        try store.delete(good.id, deleteAudio: true)
        try expect(!fm.fileExists(atPath: lib.callDirectory(good.id).path))
        try expect(fm.fileExists(atPath: lib.calls.path), "the calls folder itself must stay")
    }

    suite.test("reconcile() re-renders Markdown for JSON edited while Kan wasn't running or read since") {
        let lib = TestLibrary("lib-reconcile-offline")
        let record = Fixture.record(title: "Edited offline", speakers: Fixture.speakers(others: ["Speaker 1"]))
        let files = try lib.store.save(record)
        func renameSpeaker(_ name: String) async throws {
            try await Task.sleep(nanoseconds: 20_000_000)         // a later modification time than Kan's write
            var json = try JSONDecoder.kan.decode(CallRecord.self, from: Data(contentsOf: files.json))
            json.speakers[1].name = name
            json.speakers[1].nameSource = .user
            try JSONEncoder.kanPretty.encode(json).write(to: files.json)
        }
        func markdown() throws -> String { try String(contentsOf: files.markdown, encoding: .utf8) }

        try await renameSpeaker("Rahim")                         // an agent, while Kan is quit
        let relaunched = lib.reopened()
        try relaunched.reload()                                  // what the app does at launch
        try expectEqual(try relaunched.reconcile(), [record.id])
        let rerendered = try markdown()
        try expect(rerendered.contains("people: [\"Nahian\", \"Rahim\"]"), rerendered)
        try expectEqual(try relaunched.reconcile(), [])

        try await renameSpeaker("Karim")                         // while Kan runs…
        _ = try relaunched.record(record.id)                     // …and reads the call before reconciling
        try expectEqual(try relaunched.reconcile(), [record.id])
        let again = try markdown()
        try expect(again.contains("\"Karim\""), again)
        try checkIndexes(lib, store: relaunched)

        // A Markdown file newer than its JSON was edited by hand; it is regenerated on the next save.
        try await Task.sleep(nanoseconds: 20_000_000)
        try Data("hand edited\n".utf8).write(to: files.markdown)
        try expectEqual(try lib.reopened().reconcile(), [])
        try expectEqual(try markdown(), "hand edited\n")
    }

    suite.test("a call moved in Finder is found again by update() and delete(), never another call's file") {
        let lib = TestLibrary("lib-moved-live")
        let record = Fixture.record(title: "Filed while processing")
        let files = try lib.store.save(record)
        func move(_ files: CallFiles, to folder: String) throws -> CallFiles {
            let directory = lib.url(folder)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let moved = CallFiles(markdown: directory.appendingPathComponent(files.markdown.lastPathComponent),
                                  json: directory.appendingPathComponent(files.json.lastPathComponent))
            try fm.moveItem(at: files.json, to: moved.json)
            try fm.moveItem(at: files.markdown, to: moved.markdown)
            return moved
        }
        // The transcript arrives before the file watcher noticed the move.
        let inResearch = try move(files, to: "Research")
        try lib.store.update(record.id) { $0.segments = [Fixture.segment(0, 0, 1, "s1", "the transcript")] }
        try expectEqual(lib.store.summary(record.id)?.folder, "Research")
        try expectEqual(try lib.reopened().record(record.id).segments.map(\.text), ["the transcript"])
        try expectEqual(lib.files().filter { $0.hasSuffix(".json") && $0.contains("/") },
                        ["Research/2026-11-14 1000 Filed while processing.json"])

        // Moved again; another call's file now sits where it was indexed.
        let indexed = try expectNotNil(lib.store.files(for: record.id))
        try expectEqual(indexed.json.path, inResearch.json.path)
        let inArchive = try move(indexed, to: "Archive")
        let other = Fixture.record(title: "Filed while processing", folder: "Research")
        try TranscriptRenderer.json(other).write(to: inResearch.json)
        try lib.store.delete(record.id, deleteAudio: false)
        try expect(fm.fileExists(atPath: inResearch.json.path), "another call's file was deleted")
        try expect(!fm.fileExists(atPath: inArchive.json.path) && !fm.fileExists(atPath: inArchive.markdown.path))
        try expect(!lib.store.contains(record.id))
        try expect(lib.store.contains(other.id))
    }

    suite.test("a Finder duplicate doesn't take the call over, and deleting the call removes every copy") {
        let lib = TestLibrary("lib-duplicates")
        let record = Fixture.record(title: "Advisor meeting")
        let files = try lib.store.save(record)
        let inbox = files.json.deletingLastPathComponent()
        let copy = CallFiles(markdown: inbox.appendingPathComponent("2026-11-14 1000 Advisor meeting copy.md"),
                             json: inbox.appendingPathComponent("2026-11-14 1000 Advisor meeting copy.json"))
        try fm.copyItem(at: files.json, to: copy.json)                   // " copy" sorts before "."
        try fm.copyItem(at: files.markdown, to: copy.markdown)
        let elsewhere = lib.url("Elsewhere")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)   // "Elsewhere" sorts before "Inbox"
        try fm.copyItem(at: files.json, to: elsewhere.appendingPathComponent(files.json.lastPathComponent))

        let store = lib.reopened()
        try store.reload()
        try expectEqual(store.files(for: record.id)?.json.path, files.json.path)
        try expectEqual(store.summary(record.id)?.folder, "")
        try store.update(record.id) { $0.notes = "edited" }
        try expectEqual(store.files(for: record.id)?.json.path, files.json.path)
        try expect(fm.fileExists(atPath: copy.json.path), "the user's copy is left alone while the call exists")
        try store.delete(record.id, deleteAudio: false)
        for url in [files.json, files.markdown, copy.json, copy.markdown, elsewhere.appendingPathComponent(files.json.lastPathComponent)] {
            try expect(!fm.fileExists(atPath: url.path), "\(url.lastPathComponent) survived the delete")
        }
        try expectEqual(try lib.reopened().reload().count, 0)                // the call doesn't come back
    }

    suite.test("copies of a call move with a renamed folder and still go when the call is deleted") {
        let lib = TestLibrary("lib-duplicates-renamed")
        let record = Fixture.record(title: "Seminar", folder: "Research")
        let files = try lib.store.save(record)
        let sub = lib.url("Research/Drafts")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try fm.copyItem(at: files.json, to: sub.appendingPathComponent(files.json.lastPathComponent))
        let store = lib.reopened()
        try store.reload()
        try expectEqual(store.summary(record.id)?.folder, "Research")
        try store.renameFolder("Research", to: "Projects")
        try store.delete(record.id, deleteAudio: false)
        try expect(!fm.fileExists(atPath: lib.url("Projects/Drafts/\(files.json.lastPathComponent)").path), "\(lib.files())")
        try expectEqual(try lib.reopened().reload().count, 0)
    }

    suite.test("an old copy left by an interrupted rename is removed when the call is saved again") {
        let lib = TestLibrary("lib-leftover")
        let record = Fixture.record(title: "Old title")
        let old = try lib.store.save(record)
        let leftover = (try Data(contentsOf: old.json), try Data(contentsOf: old.markdown))
        try lib.store.update(record.id) { $0.title = "New title" }
        try leftover.0.write(to: old.json)                                   // as if Kan quit before removing them
        try leftover.1.write(to: old.markdown)
        let backup = lib.url("Backup")
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        let current = try expectNotNil(lib.store.files(for: record.id))
        let kept = backup.appendingPathComponent(current.json.lastPathComponent)
        try fm.copyItem(at: current.json, to: kept)                          // a copy the user made on purpose

        let store = lib.reopened()
        try store.reload()
        try expectEqual(store.summary(record.id)?.title, "New title")
        try store.update(record.id) { $0.starred = true }
        try expect(!fm.fileExists(atPath: old.json.path) && !fm.fileExists(atPath: old.markdown.path), "\(lib.files())")
        try expect(fm.fileExists(atPath: kept.path))
        try expectEqual(store.files(for: record.id)?.json.lastPathComponent, "2026-11-14 1000 New title.json")
        try store.delete(record.id, deleteAudio: false)
        try expect(!fm.fileExists(atPath: kept.path))
        try expectEqual(try lib.reopened().reload().count, 0)
    }

    suite.test("index.md and index.jsonl the folder already had are never overwritten") {
        let lib = TestLibrary("lib-foreign-index")
        try fm.createDirectory(at: lib.root, withIntermediateDirectories: true)
        let home = "# My vault home\n\nprecious hand-written notes\n"
        let data = "{\"note\": \"my own data\"}\n"
        try Data(home.utf8).write(to: lib.url("index.md"))
        try Data(data.utf8).write(to: lib.url("index.jsonl"))
        try lib.store.save(Fixture.record(title: "One"))
        try lib.store.writeIndexes()
        _ = try lib.store.reconcile()
        try expectEqual(lib.read("index.md"), home)
        try expectEqual(lib.read("index.jsonl"), data)
        try expect(fm.fileExists(atPath: lib.url("AGENTS.md").path))

        // Without them, Kan writes (and then keeps updating) its own.
        try fm.removeItem(at: lib.url("index.md"))
        try fm.removeItem(at: lib.url("index.jsonl"))
        try lib.store.save(Fixture.record(title: "Two"))
        try expect(lib.read("index.md").hasPrefix("<!-- kan-index"), lib.read("index.md"))
        try checkIndexes(lib)
        try lib.store.save(Fixture.record(title: "Three"))
        try checkIndexes(lib)
        // Kan still recognizes its index.jsonl when the first summary is longer than what it reads.
        try lib.store.save(Fixture.record(title: String(repeating: "অনেক লম্বা শিরোনাম ", count: 4000)))
        try lib.store.save(Fixture.record(title: "Four"))
        try checkIndexes(lib)
        // An index.md written by an older Kan (no marker yet) is Kan's too.
        try Data("# Kan call library\n\nEvery call Kan recorded…\n".utf8).write(to: lib.url("index.md"))
        try lib.store.writeIndexes()
        try checkIndexes(lib)
    }

    suite.test("a missing root is an empty library; one this process may not read is an error") {
        let base = temporaryDirectory("lib-denied-root")
        let missing = LibraryStore(root: base.appendingPathComponent("Nothing here"))
        try expectEqual(try missing.reload().count, 0)
        try expect(!missing.isRootAccessDenied, "missing isn't denied")
        let documents = base.appendingPathComponent("Documents", isDirectory: true)
        let root = documents.appendingPathComponent("Kan", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try expect(!LibraryStore(root: root).isRootAccessDenied)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: documents.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: documents.path) }
        try expect(LibraryStore(root: root).isRootAccessDenied, "a root that can't be looked at")
        do {
            _ = try LibraryStore(root: root).reload()
            throw fail("a root that can't be looked at loaded as an empty library")
        } catch LibraryError.io(let message) {
            try expect(message.contains("was denied") && message.contains("Files & Folders"), message)
        }
        // The root itself can't be listed: the same explanation.
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: documents.path)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }
        try expect(LibraryStore(root: root).isRootAccessDenied, "a root that can't be listed")
        do {
            _ = try LibraryStore(root: root).reload()
            throw fail("an unlistable root loaded as an empty library")
        } catch LibraryError.io(let message) {
            try expect(message.contains("was denied"), message)
        }
    }

    suite.test("the log names calls by id, never by title, folder, file name or person") {
        // The log outlives deleted calls. Every name below contains "Secret".
        let lib = TestLibrary("lib-log-privacy")
        let id = CallID.generate()
        let record = Fixture.record(id: id, title: "Secret plan", folder: "Secret Lab/Inner",
                                    speakers: Fixture.speakers(others: ["Dr. Secretname"]))
        let unreadable = lib.url("Secret Private")
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unreadable.path) }
        let text = try await loggedText {
            try lib.store.save(record)
            try lib.store.update(id) { $0.title = "Secret plan with Dr. Secretname" }        // a new file name
            try lib.store.update(id) { $0.folder = "Secret Lab/Other" }                       // another folder
            try lib.store.renameFolder("Secret Lab/Other", to: "Secret Lab/Moved")
            // Found by a rescan: a Finder copy elsewhere, a corrupt record, an unreadable folder.
            let current = try expectNotNil(lib.store.files(for: id))
            try fm.createDirectory(at: lib.url("Secret Copies"), withIntermediateDirectories: true)
            try fm.copyItem(at: current.json, to: lib.url("Secret Copies/Secret plan copy.json"))
            // Another call whose segments became a string: the decoding error must not quote it.
            var corrupt = try expectNotNil(try JSONSerialization.jsonObject(with: Data(contentsOf: current.json)) as? [String: Any])
            corrupt["id"] = CallID.generate().rawValue
            corrupt["title"] = "Secret broken"
            corrupt["segments"] = "Secret words"
            try JSONSerialization.data(withJSONObject: corrupt).write(to: lib.url("Secret Lab/Secret broken.json"))
            try fm.createDirectory(at: unreadable, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
            try lib.store.reload()
            try lib.store.deleteFolder("Secret Lab")
            try lib.store.delete(id, deleteAudio: false)
        }
        for line in ["Moved call \(id) (new title)", "Moved call \(id) to another folder", "Renamed a folder (1 call(s) in it)",
                     "Two files hold call \(id)", "Skipping a corrupt call record (call ", "in a folder 1 level(s) down",
                     "Skipping an unreadable folder 1 level(s) down", "Deleted a folder (", "Removed another copy of call \(id)",
                     "Deleted call \(id)"] {
            try expect(text.contains(line), "the log says “\(line)”:\n\(text)")
        }
        try expect(!text.contains("Secret"), "no title, folder, file name or person in the log:\n\(text)")
    }

    return suite
}

/// index.jsonl and index.md list exactly the store's calls, newest first, with working links.
func checkIndexes(_ lib: TestLibrary, store: LibraryStore? = nil, file: String = #fileID, line: Int = #line) throws {
    let summaries = (store ?? lib.store).summaries()
    let lines = lib.read("index.jsonl").split(separator: "\n").map(String.init)
    try expectEqual(lines.count, summaries.count, "index.jsonl lines", file: file, line: line)
    let decoded = try lines.map { try JSONDecoder.kan.decode(CallSummary.self, from: Data($0.utf8)) }
    try expectEqual(decoded.map(\.id), summaries.map(\.id), "index.jsonl order", file: file, line: line)
    try expectEqual(decoded.map(\.title), summaries.map(\.title), file: file, line: line)
    try expectEqual(decoded.map(\.folder), summaries.map(\.folder), file: file, line: line)
    let markdown = lib.read("index.md")
    try expect(markdown.contains("| Date | Title | Folder | Tags | Duration | People | Status |"), file: file, line: line)
    let rows = markdown.split(separator: "\n").filter { $0.hasPrefix("| 20") }
    try expectEqual(rows.count, summaries.count, "index.md rows", file: file, line: line)
    for (row, summary) in zip(rows, summaries) {
        guard let open = row.range(of: "](<"), let close = row[open.upperBound...].range(of: ">)") else {
            throw fail("no link in \(row)", file: file, line: line)
        }
        let target = String(row[open.upperBound..<close.lowerBound])
        try expectEqual(target, summary.markdownPath, file: file, line: line)
        try expect(FileManager.default.fileExists(atPath: lib.url(target).path), "\(target) missing", file: file, line: line)
        try expect(row.hasSuffix("| \(summary.status.rawValue) |"), String(row), file: file, line: line)
    }
}
