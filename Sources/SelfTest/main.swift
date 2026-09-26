@testable import GrabbytCore
import Foundation

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0
func expect(_ ok: Bool, _ note: String = "", line: Int = #line) {
    checks += 1
    if !ok { failures += 1; print("✘ línea \(line) \(note)") }
}

struct ErrorClassifierTests {
    func testKnownErrors() {
        let cases: [(String, FailureKind)] = [
            ("ERROR: [twitter] 123: No video could be found in this tweet", .noMedia),
            ("ERROR: [Instagram] abc: Requested content is not available, rate-limit reached or login required. Use --cookies", .rateLimited),
            ("ERROR: [youtube] x: Sign in to confirm you're not a bot. Use --cookies-from-browser", .loginRequired),
            ("ERROR: Unsupported URL: https://example.com", .unsupportedURL),
            ("ERROR: [generic] Unable to download webpage: HTTP Error 403: Forbidden", .blocked),
            ("ERROR: [youtube] x: Requested format is not available. Use --list-formats", .formatUnavailable),
            ("ERROR: [tiktok] 1: Unable to extract webpage video data; please report this issue", .extractorBroken),
            ("ERROR: could not find chrome cookies database in \"/Users/x\"", .cookieFailure),
            ("ERROR: [youtube] x: Video unavailable", .notFound),
            ("ERROR: [youtube] aaaaaaaaaaa: This video is unavailable", .notFound),
            ("ERROR: [twitter] 2091402173473050732: Video #1 is unavailable", .loginRequired),
            ("ERROR: [twitter] 1: This tweet is unavailable", .notFound),
            ("ERROR: [youtube] x: The uploader has not made this video available in your country", .geoBlocked),
            ("ERROR: Unable to download webpage: <urlopen error [Errno 8] nodename nor servname provided>", .network),
            ("ERROR: something totally new", .unknown),
        ]
        for (text, expected) in cases {
            expect(ErrorClassifier.classify(text) == expected, text)
        }
    }

    func testIgnoresWarningsWhenErrorPresent() {
        let out = "WARNING: [youtube] cookies are no longer valid\nERROR: [youtube] x: Video unavailable"
        expect(ErrorClassifier.classify(out) == .notFound)
    }
}

struct AttemptPlannerTests {
    func testLoginWalksThroughBrowsersThenGivesUp() {
        var p = AttemptPlanner(installedBrowsers: [.chrome, .firefox, .safari], preferredBrowser: .firefox)
        var c = p.first(hasFfmpeg: true)
        expect(c.mergeFormats)
        c = p.next(after: .loginRequired, previous: c, canUpdate: true)!
        expect(c.cookies == .firefox, "preferido primero")
        c = p.next(after: .cookieFailure, previous: c, canUpdate: true)!
        expect(c.cookies == .chrome)
        c = p.next(after: .loginRequired, previous: c, canUpdate: true)!
        expect(c.cookies == .safari)
        var seen = 0
        while let n = p.next(after: .loginRequired, previous: c, canUpdate: true) { c = n; seen += 1; expect(seen < 10) }
    }

    func testFormatErrorFallsBackToSingleFile() {
        var p = AttemptPlanner(installedBrowsers: [], preferredBrowser: nil)
        let c = p.first(hasFfmpeg: true)
        let n = p.next(after: .ffmpegMissing, previous: c, canUpdate: true)!
        expect(!n.mergeFormats)
    }

    func testExtractorBrokenUpdatesOnceThenImpersonates() {
        var p = AttemptPlanner(installedBrowsers: [], preferredBrowser: nil)
        let c = p.first(hasFfmpeg: true)
        let u = p.next(after: .extractorBroken, previous: c, canUpdate: true)!
        expect(u.updateFirst)
        let i = p.next(after: .extractorBroken, previous: u, canUpdate: true)!
        expect(!i.updateFirst)
        expect(i.impersonate)
    }

    func testTerminalFailuresStop() {
        var p = AttemptPlanner(installedBrowsers: [.chrome], preferredBrowser: nil)
        let c = p.first(hasFfmpeg: true)
        expect(p.next(after: .unsupportedURL, previous: c, canUpdate: true) == nil)
        expect(p.next(after: .geoBlocked, previous: c, canUpdate: true) == nil)
    }

    func testAlwaysTerminates() {
        for kind in FailureKind.allCases {
            var p = AttemptPlanner(installedBrowsers: Browser.allCases, preferredBrowser: nil)
            var c = p.first(hasFfmpeg: true)
            var n = 0
            while let next = p.next(after: kind, previous: c, canUpdate: true) { c = next; n += 1 }
            expect(n <= 10, kind.rawValue)
        }
    }
}

struct ParsingTests {
    func testProgressLine() {
        if case .progress(let f?, let s, let e)? = YtDlpArguments.parse(line: "GRBP|  45.3%|2.10MiB/s|00:12") {
            expect(abs(f - 0.453) < 0.0001 && s == "2.10MiB/s" && e == "00:12")
        } else { expect(false, "progress") }
        expect(YtDlpArguments.parse(line: "GRBP|Unknown %|NA|NA") == .progress(nil, nil, nil))
        expect(YtDlpArguments.parse(line: "GRBF|/tmp/a b.mp4") == .file("/tmp/a b.mp4"))
        expect(YtDlpArguments.parse(line: "[download] Destination: x") == nil)
    }

    func testTweetID() {
        expect(TwitterFallback.tweetID(from: "https://x.com/a/status/123?s=20") == "123")
        expect(TwitterFallback.tweetID(from: "https://twitter.com/a/status/456/video/1") == "456")
        expect(TwitterFallback.tweetID(from: "https://mobile.twitter.com/a/status/7") == "7")
        expect(TwitterFallback.tweetID(from: "https://youtube.com/a/status/7") == nil)
    }

    func testLinkParser() {
        expect(LinkParser.firstURL(in: "mira esto https://x.com/u/status/1?s=20 jaja") == "https://x.com/u/status/1?s=20")
        expect(LinkParser.firstURL(in: "x.com/u/status/1") == "https://x.com/u/status/1")
        expect(LinkParser.firstURL(in: "hola") == nil)
    }
}

// `swift run SelfTest fx <url> [audio]`: prueba solo el fallback de fxtwitter.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "fx", let id = TwitterFallback.tweetID(from: CommandLine.arguments[2]) {
    let mode: MediaMode = CommandLine.arguments.dropFirst(3).first == "audio" ? .audio : .video
    let dest = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grabbyt-test")
    try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    do {
        let files = try await TwitterFallback.download(tweetID: id, mode: mode, destination: dest, ffmpeg: await ToolManager.shared.path(for: .ffmpeg)) { print("  \($0)") }
        print("OK", files.map(\.lastPathComponent))
    } catch { print("ERROR", error.localizedDescription) }
    exit(0)
}

// `swift run SelfTest download <url> [audio]`: prueba real del motor completo (instala herramientas si faltan).
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "download" {
    let url = CommandLine.arguments[2]
    let mode: MediaMode = CommandLine.arguments.dropFirst(3).first == "audio" ? .audio : .video
    let dest = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grabbyt-test")
    let tools = ToolManager.shared
    do {
        try await tools.installMissing { print("· \($0)") }
    } catch { print("instalación: \(error.localizedDescription)") }
    for tool in Tool.allCases { let i = await tools.info(for: tool); print("  \(tool.rawValue): \(i.version ?? "—") \(i.managed ? "(Grabbyt)" : "(sistema)")") }
    let outcome = await DownloadEngine().run(DownloadRequest(url: url, mode: mode, destination: dest, preferredBrowser: nil)) { event in
        switch event {
        case .attempt(let n, let c): print("→ intento \(n): \(c.summary)")
        case .attemptFailed(let k): print("  ✗ \(k.rawValue)")
        case .title(let t): print("  título: \(t)")
        case .status(let s): print("  \(s)")
        case .log(let l): if l.contains("ERROR") || l.contains("WARNING") { print("  | \(l)") }
        case .progress: break
        case .fallback(let f): print("→ fallback: \(f)")
        }
    }
    print(outcome)
    exit(0)
}

ErrorClassifierTests().testKnownErrors()
ErrorClassifierTests().testIgnoresWarningsWhenErrorPresent()
AttemptPlannerTests().testLoginWalksThroughBrowsersThenGivesUp()
AttemptPlannerTests().testFormatErrorFallsBackToSingleFile()
AttemptPlannerTests().testExtractorBrokenUpdatesOnceThenImpersonates()
AttemptPlannerTests().testTerminalFailuresStop()
AttemptPlannerTests().testAlwaysTerminates()
ParsingTests().testProgressLine()
ParsingTests().testLinkParser()
ParsingTests().testTweetID()
print(failures == 0 ? "✔ \(checks) comprobaciones OK" : "✘ \(failures)/\(checks) fallaron")
exit(failures == 0 ? 0 : 1)
