#if canImport(Foundation) && !os(iOS) && !os(tvOS) && !os(watchOS)
import XCTest
import Foundation

/// Shell-level smoke tests for `Scripts/allstak-upload-dsyms.sh`, the build-time
/// dSYM upload helper. The script is CI/build tooling and is *not* part of the
/// SwiftPM build graph; these tests drive it as a subprocess in `--dry-run` mode
/// so they make no network calls and need no real backend or token.
///
/// They assert the script:
///   • discovers `.dSYM` bundles and their `Contents/Resources/DWARF/<binary>`,
///   • constructs the correct endpoint target (POST .../api/v1/dsyms/upload
///     with `projectId` + `name` query params) for each slice,
///   • returns CI-friendly exit codes (0 ok, 1 bad usage, 3 nothing to upload).
///
/// Everything skips gracefully when the host can't launch subprocesses (e.g. a
/// sandboxed iOS/tvOS test runner) or when the script can't be located.
final class UploadDsymsScriptTests: XCTestCase {

    /// Absolute path to the script, derived from this test file's location
    /// (`<repo>/Tests/AllStakTests/<this>` -> `<repo>/Scripts/...`).
    private func scriptPath() -> String? {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()  // AllStakTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let script = repoRoot
            .appendingPathComponent("Scripts")
            .appendingPathComponent("allstak-upload-dsyms.sh")
        return FileManager.default.fileExists(atPath: script.path) ? script.path : nil
    }

    /// Run `/bin/sh <script> <args...>` and capture (stdout+stderr, exitCode).
    /// Returns nil if Process is unavailable on this platform.
    private func runScript(_ script: String, _ args: [String], env: [String: String]? = nil) -> (output: String, code: Int32)? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = [script] + args
        if let env { proc.environment = env }
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
        } catch {
            return nil  // subprocess launch not permitted here — caller skips
        }
        // Read before waiting to avoid deadlock on large output (output here is tiny).
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), proc.terminationStatus)
    }

    /// Build a throwaway `.dSYM` bundle with one DWARF binary and return its dir.
    private func makeFakeDsym(binaryName: String = "MyApp") throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("allstak-dsym-test-" + UUID().uuidString)
        let dwarfDir = root
            .appendingPathComponent("\(binaryName).app.dSYM")
            .appendingPathComponent("Contents/Resources/DWARF")
        try FileManager.default.createDirectory(at: dwarfDir, withIntermediateDirectories: true)
        try Data("fake DWARF mach-o bytes".utf8)
            .write(to: dwarfDir.appendingPathComponent(binaryName))
        return root
    }

    // MARK: dry-run target construction

    func testDryRunListsConstructedUploadTarget() throws {
        guard let script = scriptPath() else {
            throw XCTSkip("upload script not found next to package")
        }
        let dir = try makeFakeDsym(binaryName: "MyApp")
        defer { try? FileManager.default.removeItem(at: dir) }

        guard let run = runScript(script, [
            "--dry-run",
            "--api", "https://api.allstak.test",
            "--project-id", "11111111-2222-3333-4444-555555555555",
            "--token", "ci-token",
            "--path", dir.path,
        ]) else {
            throw XCTSkip("subprocess launch unavailable on this host")
        }

        XCTAssertEqual(run.code, 0, "dry-run of a valid dSYM must exit 0. Output:\n\(run.output)")
        XCTAssertTrue(run.output.contains("DRY-RUN would upload: MyApp"),
                      "must report the discovered DWARF binary. Output:\n\(run.output)")
        XCTAssertTrue(run.output.contains(
            "POST https://api.allstak.test/api/v1/dsyms/upload?projectId=11111111-2222-3333-4444-555555555555&name=MyApp"),
            "must construct the correct endpoint with projectId + name. Output:\n\(run.output)")
        XCTAssertTrue(run.output.contains("1/1 uploaded"),
                      "summary must count the single slice. Output:\n\(run.output)")
    }

    func testDryRunFindsMultipleDsymsUnderADirectory() throws {
        guard let script = scriptPath() else { throw XCTSkip("upload script not found") }

        // Two .dSYM bundles in one tree (app + framework).
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("allstak-multi-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["App", "Lib"] {
            let dwarf = root
                .appendingPathComponent("\(name).dSYM/Contents/Resources/DWARF")
            try FileManager.default.createDirectory(at: dwarf, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dwarf.appendingPathComponent(name))
        }

        guard let run = runScript(script, [
            "--dry-run", "--api", "https://h.test", "--project-id", "p", "--token", "t",
            "--path", root.path,
        ]) else { throw XCTSkip("subprocess unavailable") }

        XCTAssertEqual(run.code, 0, run.output)
        XCTAssertTrue(run.output.contains("would upload: App"), run.output)
        XCTAssertTrue(run.output.contains("would upload: Lib"), run.output)
        XCTAssertTrue(run.output.contains("2/2 uploaded"), run.output)
    }

    func testReadsXcodeDsymEnvVarsWhenNoPathGiven() throws {
        guard let script = scriptPath() else { throw XCTSkip("upload script not found") }
        let dir = try makeFakeDsym(binaryName: "EnvApp")
        defer { try? FileManager.default.removeItem(at: dir) }

        var env = ProcessInfo.processInfo.environment
        env["DWARF_DSYM_FOLDER_PATH"] = dir.path
        env["DWARF_DSYM_FILE_NAME"] = "EnvApp.app.dSYM"

        guard let run = runScript(script, ["--dry-run"], env: env) else {
            throw XCTSkip("subprocess unavailable")
        }
        XCTAssertEqual(run.code, 0, run.output)
        XCTAssertTrue(run.output.contains("would upload: EnvApp"),
                      "must honor Xcode DWARF_DSYM_* env vars. Output:\n\(run.output)")
    }

    // MARK: exit codes

    func testMissingRequiredInputsExitsOne() throws {
        guard let script = scriptPath() else { throw XCTSkip("upload script not found") }
        let dir = try makeFakeDsym()
        defer { try? FileManager.default.removeItem(at: dir) }

        // No --dry-run, no api/project/token, and a clean env so no ALLSTAK_* leak in.
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "ALLSTAK_API")
        env.removeValue(forKey: "ALLSTAK_PROJECT_ID")
        env.removeValue(forKey: "ALLSTAK_AUTH_TOKEN")

        guard let run = runScript(script, ["--path", dir.path], env: env) else {
            throw XCTSkip("subprocess unavailable")
        }
        XCTAssertEqual(run.code, 1, "missing api/project/token must exit 1. Output:\n\(run.output)")
        XCTAssertTrue(run.output.contains("missing API base"), run.output)
    }

    func testNoDsymFoundExitsThree() throws {
        guard let script = scriptPath() else { throw XCTSkip("upload script not found") }
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("allstak-empty-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        guard let run = runScript(script, ["--dry-run", "--path", empty.path]) else {
            throw XCTSkip("subprocess unavailable")
        }
        XCTAssertEqual(run.code, 3, "no .dSYM under the path must exit 3. Output:\n\(run.output)")
    }

    func testHelpExitsZero() throws {
        guard let script = scriptPath() else { throw XCTSkip("upload script not found") }
        guard let run = runScript(script, ["--help"]) else { throw XCTSkip("subprocess unavailable") }
        XCTAssertEqual(run.code, 0)
        XCTAssertTrue(run.output.contains("allstak-upload-dsyms"), run.output)
    }

    // MARK: optional shellcheck lint (skips when shellcheck isn't installed)

    /// Find an executable on PATH (plus common Homebrew dirs), or nil.
    private func resolveOnPath(_ tool: String) -> String? {
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        for dir in dirs {
            let candidate = dir + "/" + tool
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    func testShellcheckCleanWhenAvailable() throws {
        guard let script = scriptPath() else { throw XCTSkip("upload script not found") }
        guard let bin = resolveOnPath("shellcheck") else {
            throw XCTSkip("shellcheck not installed — skipping lint")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = ["-S", "warning", script]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch { throw XCTSkip("could not launch shellcheck") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(proc.terminationStatus, 0,
                       "shellcheck reported issues at warning level:\n\(out)")
    }
}
#endif
