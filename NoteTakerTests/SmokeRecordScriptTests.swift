import Foundation
import Testing

@Suite("Smoke record script validation")
struct SmokeRecordScriptTests {
    @Test("mic and system mode reaches output validation")
    func micAndSystemModeReachesOutputValidation() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["scripts/smoke-record.sh", "/tmp/nonexistent.app"]
        process.currentDirectoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        var environment = ProcessInfo.processInfo.environment
        environment["MODE"] = "micAndSystem"
        environment["SECONDS"] = "1"
        environment["OUTPUT"] = ""
        process.environment = environment

        let standardError = Pipe()
        process.standardError = standardError
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = String(decoding: errorData, as: UTF8.self)

        #expect(process.terminationStatus == 2)
        #expect(errorOutput == "Unsupported smoke OUTPUT: empty path.\n")
    }

    @Test("script validates explicit smoke clock values before launch")
    func scriptValidatesExplicitClockValuesBeforeLaunch() throws {
        let result = try runSmokeScript(environment: [
            "MODE": "micAndSystem",
            "SECONDS": "1",
            "OUTPUT": "/tmp/notetaker-script-clock-\(UUID().uuidString).m4a",
            "CLOCK": "display",
        ])

        #expect(result.exitCode == 2)
        #expect(result.standardError == "Unsupported smoke CLOCK: display; expected microphone or output.\n")
    }

    @Test("script passes explicit output clock to the app launch arguments")
    func scriptPassesExplicitOutputClockToAppLaunchArguments() throws {
        let fixture = try SmokeScriptFixture()
        defer { fixture.cleanup() }

        let result = try runSmokeScript(environment: fixture.environment(
            mode: "micAndSystem",
            clock: "output"
        ))

        #expect(result.exitCode == 0, Comment(rawValue: result.standardError))
        let arguments = try String(contentsOf: fixture.openLogURL, encoding: .utf8)
        #expect(arguments.contains("--clock\noutput\n"))
    }

    @Test("script starts stimulus for system-only and mic-and-system modes")
    func scriptStartsStimulusForSystemOnlyAndMicAndSystemModes() throws {
        for mode in ["systemOnly", "micAndSystem"] {
            let fixture = try SmokeScriptFixture()
            defer { fixture.cleanup() }

            let result = try runSmokeScript(environment: fixture.environment(mode: mode))

            #expect(result.exitCode == 0, Comment(rawValue: result.standardError))
            let stimulusLog = try String(contentsOf: fixture.stimulusLogURL, encoding: .utf8)
            #expect(stimulusLog == "\(fixture.normalizedOutputPath)\n")
        }
    }

    @Test("Make smoke accepts output clock and rejects unsupported clocks")
    func makeSmokeValidatesClockParameter() throws {
        let accepted = try runMakeSmoke(arguments: [
            "-n",
            "smoke",
            "MODE=micAndSystem",
            "CLOCK=output",
            "OUTPUT=/tmp/notetaker-make-clock-\(UUID().uuidString).m4a",
        ])
        #expect(accepted.exitCode == 0, Comment(rawValue: accepted.standardError))
        #expect(accepted.standardOutput.contains("scripts/smoke-record.sh"))

        let rejected = try runMakeSmoke(arguments: [
            "-n",
            "smoke",
            "MODE=micAndSystem",
            "CLOCK=display",
            "OUTPUT=/tmp/notetaker-make-clock-\(UUID().uuidString).m4a",
        ])
        #expect(rejected.exitCode == 2)
        #expect(rejected.standardError.contains("Unsupported smoke CLOCK: display; expected microphone or output"))
    }

    @Test("Make smoke exports clock to invoked script")
    func makeSmokeExportsClockToInvokedScript() throws {
        let fixture = try MakeSmokeFixture()
        defer { fixture.cleanup() }

        let result = try runMakeSmoke(
            arguments: [
                "-f", "Makefile",
                "-f", "override.mk",
                "smoke",
                "MODE=micAndSystem",
                "CLOCK=output",
                "OUTPUT=\(fixture.outputURL.path)",
            ],
            currentDirectory: fixture.directory
        )

        #expect(result.exitCode == 0, Comment(rawValue: result.standardError))
        #expect(try String(contentsOf: fixture.clockLogURL, encoding: .utf8) == "output\n")
    }
}

private struct SmokeScriptResult {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

private struct MakeSmokeFixture {
    let directory: URL
    let outputURL: URL
    let clockLogURL: URL

    init() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakeSmoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        outputURL = directory.appendingPathComponent("output.m4a")
        clockLogURL = directory.appendingPathComponent("clock.txt")

        try FileManager.default.copyItem(
            at: repositoryRoot.appendingPathComponent("Makefile"),
            to: directory.appendingPathComponent("Makefile")
        )
        try """
        build:
        \t@:
        """.write(to: directory.appendingPathComponent("override.mk"), atomically: true, encoding: .utf8)

        let scriptsDirectory = directory.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptsDirectory, withIntermediateDirectories: false)
        let fakeScriptURL = scriptsDirectory.appendingPathComponent("smoke-record.sh")
        try """
        #!/bin/zsh
        set -eu
        /usr/bin/printf '%s\\n' "${CLOCK}" > "\(clockLogURL.path)"
        /usr/bin/printf 'x' > "${OUTPUT}"
        """.write(to: fakeScriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeScriptURL.path)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct SmokeScriptFixture {
    let directory: URL
    let outputURL: URL
    let openLogURL: URL
    let stimulusLogURL: URL

    var normalizedOutputPath: String {
        let path = outputURL.path
        if path.hasPrefix("/var/") {
            return "/private" + path
        }
        return path
    }

    private let openURL: URL
    private let stimulusURL: URL
    private let pgrepURL: URL
    private let statsURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmokeRecordScript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        outputURL = directory.appendingPathComponent("output.m4a")
        openLogURL = directory.appendingPathComponent("open-args.txt")
        stimulusLogURL = directory.appendingPathComponent("stimulus-args.txt")
        openURL = directory.appendingPathComponent("fake-open")
        stimulusURL = directory.appendingPathComponent("fake-stimulus")
        pgrepURL = directory.appendingPathComponent("fake-pgrep")
        statsURL = directory.appendingPathComponent("fake-stats")

        try """
        #!/bin/zsh
        set -eu
        output=""
        previous=""
        for argument in "$@"; do
          /usr/bin/printf '%s\\n' "${argument}" >> "${SMOKE_TEST_OPEN_LOG}"
          if [[ "${previous}" == "--smoke-record" ]]; then
            previous="duration"
          elif [[ "${previous}" == "duration" ]]; then
            output="${argument}"
            previous=""
          elif [[ "${argument}" == "--smoke-record" ]]; then
            previous="--smoke-record"
          fi
        done
        /usr/bin/printf 'x' > "${output}"
        /usr/bin/printf '%s' "${NOTE_TAKER_SMOKE_RUN_TOKEN}" > "${output}.smoke-success"
        """.write(to: openURL, atomically: true, encoding: .utf8)

        try """
        #!/bin/zsh
        set -eu
        /usr/bin/printf '%s\\n' "$1" >> "${SMOKE_TEST_STIMULUS_LOG}"
        while true; do
          /bin/sleep 1
        done
        """.write(to: stimulusURL, atomically: true, encoding: .utf8)

        try """
        #!/bin/zsh
        exit 1
        """.write(to: pgrepURL, atomically: true, encoding: .utf8)

        try """
        #!/bin/zsh
        exit 0
        """.write(to: statsURL, atomically: true, encoding: .utf8)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: openURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stimulusURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pgrepURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: statsURL.path)
    }

    func environment(mode: String, clock: String = "microphone") -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["MODE"] = mode
        environment["SECONDS"] = "1"
        environment["OUTPUT"] = outputURL.path
        environment["CLOCK"] = clock
        environment["SMOKE_OPEN_CMD"] = openURL.path
        environment["SMOKE_STIMULUS_CMD"] = stimulusURL.path
        environment["SMOKE_PGREP_CMD"] = pgrepURL.path
        environment["SMOKE_AUDIO_STATS_CMD"] = statsURL.path
        environment["SMOKE_TEST_OPEN_LOG"] = openLogURL.path
        environment["SMOKE_TEST_STIMULUS_LOG"] = stimulusLogURL.path
        return environment
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func runSmokeScript(environment overrides: [String: String]) throws -> SmokeScriptResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["scripts/smoke-record.sh", "/tmp/nonexistent.app"]
    process.currentDirectoryURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    var environment = ProcessInfo.processInfo.environment
    for (key, value) in overrides {
        environment[key] = value
    }
    process.environment = environment

    let standardOutput = Pipe()
    let standardError = Pipe()
    process.standardError = standardError
    process.standardOutput = standardOutput

    try process.run()
    process.waitUntilExit()

    let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
    let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
    return SmokeScriptResult(
        exitCode: process.terminationStatus,
        standardOutput: String(decoding: outputData, as: UTF8.self),
        standardError: String(decoding: errorData, as: UTF8.self)
    )
}

private func runMakeSmoke(
    arguments: [String],
    currentDirectory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
) throws -> SmokeScriptResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/make")
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectory
    process.environment = ProcessInfo.processInfo.environment

    let standardOutput = Pipe()
    let standardError = Pipe()
    process.standardOutput = standardOutput
    process.standardError = standardError

    try process.run()
    process.waitUntilExit()

    let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
    let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
    return SmokeScriptResult(
        exitCode: process.terminationStatus,
        standardOutput: String(decoding: outputData, as: UTF8.self),
        standardError: String(decoding: errorData, as: UTF8.self)
    )
}
