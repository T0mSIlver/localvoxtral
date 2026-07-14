import Foundation

private let beginSentinel = "=== AGENT-E2E-INSPECTION-REPORT-BEGIN ==="
private let endSentinel = "=== AGENT-E2E-INSPECTION-REPORT-END ==="

private struct ReportHeader: Decodable {
    let polishModel: String
    let asrModel: String
    let audioSource: String?
}

private struct CaseRecord: Decodable {
    let caseID: String
    let stratum: String
    let pipeline: String
    let lang: String
    let spokenForm: String
    let intendedText: String
    let requiredTokens: [String]
    let transcript: String?
    let polishInputText: String?
    let rawModelOutput: String?
    let guardOffOutput: String?
    let output: String
    let skipReason: String?
    let infraFailure: String?
    let tokensFailures: [String]
    let exactTextFailures: [String]?
    let guardOffTokensFailures: [String]?
    let rewriteFailure: String?
    let rewriteIsFatal: Bool?
    let wordAccuracyVsIntended: Double?
}

private struct Manifest: Decodable {
    let recordings: [Recording]
}

private struct Recording: Decodable {
    let id: String
    let file: String
}

private struct Options {
    var openAfterWriting = false
    var logPath: String?
    var recordingDirectory: String?
}

private enum ReportError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let value): value
        }
    }
}

private struct ClassifiedRecord {
    let record: CaseRecord
    let tags: [String]
    let hasIssue: Bool
    let severity: Int
    let transcriptAccuracy: Double?
}

private func usage() -> Never {
    print(
        """
        Usage: ./scripts/render-agent-eval-report.sh [--open] LOG [RECORDING_DIRECTORY]

        Extracts the inspection JSONL from an agent E2E eval log and writes:
          RECORDING_DIRECTORY/eval-report.html   when a recording set is supplied
          LOG-directory/agent-eval-report.html   otherwise

        Put the report beside the recording manifest so its relative audio links
        remain private and continue to work when the directory moves.
        """
    )
    exit(0)
}

private func parseOptions() throws -> Options {
    var options = Options()
    var positional: [String] = []
    for argument in CommandLine.arguments.dropFirst() {
        switch argument {
        case "--open": options.openAfterWriting = true
        case "-h", "--help": usage()
        default:
            if argument.hasPrefix("-") {
                throw ReportError.message("unknown option: \(argument)")
            }
            positional.append(argument)
        }
    }
    guard (1...2).contains(positional.count) else {
        throw ReportError.message("expected LOG and optional RECORDING_DIRECTORY")
    }
    options.logPath = positional[0]
    options.recordingDirectory = positional.count == 2 ? positional[1] : nil
    return options
}

private func decodeReport(at logURL: URL) throws -> (ReportHeader, [CaseRecord]) {
    let text = try String(contentsOf: logURL, encoding: .utf8)
    let lines = text.components(separatedBy: .newlines)
    guard let begin = lines.lastIndex(of: beginSentinel),
          let end = lines[(begin + 1)...].firstIndex(of: endSentinel),
          end > begin + 1
    else {
        throw ReportError.message("no complete agent inspection report found in \(logURL.path)")
    }

    // XCTest writes its own progress to the same stdout stream as the report.
    // A status update can land in the MIDDLE of a large JSON record, as in the
    // field log where `DictationViewModelTests.swift` was split after `Tests`.
    // Remove only XCTest's rigid status-line shapes, then join fragments until
    // each JSON value parses. Do not discard a whole damaged line: it contains
    // the start of the case record we need to preserve.
    var payload = lines[(begin + 1)..<end].joined(separator: "\n") + "\n"
    let noisePatterns = [
        #"/(?:Users|home|private|Volumes|tmp)/(?:(?!/(?:Users|home|private|Volumes|tmp)/)[^\"\n])*/Tests/localvoxtralTests/AgentDictationE2EEvalTests\.swift:\d+: error: -\[localvoxtralTests\.AgentDictationE2EEvalTests [^\n]*\n"#,
        #"Test Case '-\[[^\n]*\n"#,
        #"Test Suite '[^\n]*\n"#,
        #"[ \t]*Executed [^\n]*\n"#,
    ]
    for pattern in noisePatterns {
        payload = payload.replacingOccurrences(
            of: pattern, with: "", options: .regularExpression
        )
    }

    var values: [String] = []
    var pending = ""
    var malformed = 0
    for fragment in payload.components(separatedBy: .newlines) where !fragment.isEmpty {
        if pending.isEmpty, !fragment.hasPrefix("{") { continue }
        if !pending.isEmpty, fragment.hasPrefix("{") {
            malformed += 1
            pending = ""
        }
        pending += fragment
        if (try? JSONSerialization.jsonObject(with: Data(pending.utf8))) != nil {
            values.append(pending)
            pending = ""
        }
    }
    if !pending.isEmpty {
        malformed += 1
    }
    if malformed > 0 {
        FileHandle.standardError.write(
            Data(
                "render-agent-eval-report: warning: skipped \(malformed) malformed/interleaved report value(s)\n"
                    .utf8
            )
        )
    }
    guard values.count >= 2 else {
        throw ReportError.message("inspection report contains no cases")
    }

    let decoder = JSONDecoder()
    let header = try decoder.decode(ReportHeader.self, from: Data(values[0].utf8))
    let records = try values.dropFirst().map {
        try decoder.decode(CaseRecord.self, from: Data($0.utf8))
    }
    return (header, records)
}

private func loadAudioFiles(from directory: URL?) throws -> [String: String] {
    guard let directory else { return [:] }
    let manifestURL = directory.appendingPathComponent("manifest.json")
    let manifest = try JSONDecoder().decode(
        Manifest.self, from: Data(contentsOf: manifestURL)
    )
    var files: [String: String] = [:]
    for recording in manifest.recordings {
        guard files.updateValue(recording.file, forKey: recording.id) == nil else {
            throw ReportError.message("recording manifest contains duplicate id: \(recording.id)")
        }
    }
    return files
}

private let wordRegex = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+")

private func words(in text: String) -> [String] {
    let text = text.lowercased()
    let range = NSRange(text.startIndex..., in: text)
    return wordRegex.matches(in: text, range: range).compactMap { match in
        Range(match.range, in: text).map { String(text[$0]) }
    }
}

private func wordAccuracy(expected: String, actual: String) -> Double {
    let expected = words(in: expected)
    let actual = words(in: actual)
    guard !expected.isEmpty else { return actual.isEmpty ? 1 : 0 }

    var previous = Array(0...actual.count)
    for (leftIndex, left) in expected.enumerated() {
        var current = Array(repeating: 0, count: actual.count + 1)
        current[0] = leftIndex + 1
        for (rightIndex, right) in actual.enumerated() {
            current[rightIndex + 1] = min(
                previous[rightIndex + 1] + 1,
                current[rightIndex] + 1,
                previous[rightIndex] + (left == right ? 0 : 1)
            )
        }
        previous = current
    }
    let denominator = max(expected.count, actual.count)
    return max(0, 1 - Double(previous[actual.count]) / Double(denominator))
}

private func classify(_ record: CaseRecord) -> ClassifiedRecord {
    let finalTokenFailure = !record.tokensFailures.isEmpty
    let exactFailure = !(record.exactTextFailures ?? []).isEmpty
    let rewrite = record.rewriteFailure != nil
    let fatalRewrite = record.rewriteIsFatal == true && rewrite
    let infra = record.infraFailure != nil || record.skipReason != nil
    let transcriptAccuracy = record.transcript.map {
        wordAccuracy(expected: record.spokenForm, actual: $0)
    }
    // Compare ASR with what was SPOKEN, not final truth. Spoken `dash dash`
    // becoming final `--` is a normalizer/polisher duty, not an ASR error.
    let asrMismatch = transcriptAccuracy.map { $0 < 0.999_999 } ?? false
    let finalFailure = finalTokenFailure || exactFailure || fatalRewrite
    let guardLoss = record.guardOffTokensFailures?.isEmpty == true && finalTokenFailure
    let guardSave = record.guardOffTokensFailures?.isEmpty == false && !finalTokenFailure

    var tags: [String] = []
    if record.infraFailure != nil { tags.append("infra") }
    if record.skipReason != nil { tags.append("skipped") }
    if asrMismatch {
        if record.pipeline == "asr-only" {
            tags.append("ASR mismatch")
        } else {
            tags.append(finalFailure ? "ASR unrecovered" : "polish recovered")
        }
    } else if finalFailure {
        tags.append("polish/normalizer miss")
    }
    if guardLoss { tags.append("guard loss") }
    if guardSave { tags.append("guard save") }
    if exactFailure { tags.append("exact mismatch") }
    if rewrite { tags.append("rewrite") }
    if tags.isEmpty { tags.append("pass") }

    let issue = infra || finalFailure || asrMismatch
    let severity: Int
    if record.infraFailure != nil { severity = 0 }
    else if guardLoss { severity = 1 }
    else if finalFailure && asrMismatch { severity = 2 }
    else if finalFailure { severity = 3 }
    else if asrMismatch { severity = 4 }
    else { severity = 5 }
    return ClassifiedRecord(
        record: record, tags: tags, hasIssue: issue, severity: severity,
        transcriptAccuracy: transcriptAccuracy
    )
}

private func escapeHTML(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}

private func textCell(_ value: String?) -> String {
    guard let value, !value.isEmpty else { return "<span class=muted>—</span>" }
    return escapeHTML(value)
}

private func badge(_ tag: String) -> String {
    let css: String
    if tag == "pass" || tag.hasPrefix("polish recovered") || tag.hasPrefix("guard save") {
        css = "good"
    } else if tag.hasPrefix("exact mismatch") {
        css = "warn"
    } else {
        css = "bad"
    }
    return "<span class=\"badge \(css)\">\(escapeHTML(tag))</span>"
}

private func renderHTML(
    header: ReportHeader,
    records: [CaseRecord],
    audioFiles: [String: String]
) -> String {
    let classified = records.map(classify).sorted {
        if $0.severity != $1.severity { return $0.severity < $1.severity }
        if $0.record.stratum != $1.record.stratum {
            return $0.record.stratum < $1.record.stratum
        }
        return $0.record.caseID < $1.record.caseID
    }
    let issueCount = classified.filter(\.hasIssue).count
    let strata = Set(records.map(\.stratum)).sorted()
    let tagCounts = Dictionary(grouping: classified.flatMap(\.tags), by: { $0 })
        .mapValues(\.count)

    let options = (["<option value=\"\">All strata</option>"] + strata.map {
        "<option value=\"\(escapeHTML($0))\">\(escapeHTML($0))</option>"
    }).joined()

    let rows = classified.map { item -> String in
        let record = item.record
        let audio: String
        if let file = audioFiles[record.caseID] {
            audio = "<audio controls preload=\"none\" src=\"\(escapeHTML(file))\"></audio>"
        } else {
            audio = "<span class=muted>No recording</span>"
        }
        let accuracy = [
            item.transcriptAccuracy.map { String(format: "ASR %.0f%%", $0 * 100) },
            record.wordAccuracyVsIntended.map { String(format: "final %.0f%%", $0 * 100) },
        ].compactMap { $0 }.joined(separator: " · ")
        let raw = record.rawModelOutput ?? (record.pipeline == "asr-only" ? nil : record.output)
        let finalBlock = record.rawModelOutput != nil
            ? "<div class=final-label>Final shown to user</div><div>\(textCell(record.output))</div>"
            : ""
        let diagnostics = (record.tokensFailures + (record.exactTextFailures ?? [])
            + [record.rewriteFailure, record.infraFailure, record.skipReason].compactMap { $0 })
        let details = diagnostics.isEmpty
            ? ""
            : "<details><summary>Why it failed</summary>\(escapeHTML(diagnostics.joined(separator: " · ")))</details>"

        return """
        <tr data-issue="\(item.hasIssue ? "1" : "0")" data-stratum="\(escapeHTML(record.stratum))">
          <td class=meta>
            <strong>\(escapeHTML(record.caseID))</strong>
            <div class=muted>\(escapeHTML(record.stratum)) · \(escapeHTML(record.lang))</div>
            <div class=badges>\(item.tags.map(badge).joined())</div>
            <div class=muted>\(escapeHTML(accuracy))</div>
            \(details)
          </td>
          <td>\(audio)<details><summary>Spoken phrase</summary>\(textCell(record.spokenForm))</details></td>
          <td class=text>\(textCell(record.transcript))</td>
          <td class="text \(item.hasIssue ? "issue" : "")">\(textCell(raw))\(finalBlock)</td>
          <td class="text truth">\(textCell(record.intendedText))</td>
        </tr>
        """
    }.joined(separator: "\n")

    func count(_ tag: String) -> Int { tagCounts[tag] ?? 0 }
    return """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>localvoxtral agent eval</title>
      <style>
        :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
        body { margin: 0; font-size: 14px; }
        header { padding: 18px 22px 10px; border-bottom: 1px solid #8885; }
        h1 { margin: 0 0 5px; font-size: 20px; }
        .muted { color: #777; font-size: 12px; }
        .counts { margin-top: 9px; display: flex; flex-wrap: wrap; gap: 7px; }
        .toolbar { position: sticky; top: 0; z-index: 3; padding: 9px 22px; background: Canvas; border-bottom: 1px solid #8885; }
        button, select { font: inherit; padding: 5px 9px; margin-right: 5px; }
        button.active { font-weight: 650; }
        table { width: 100%; border-collapse: collapse; table-layout: fixed; }
        th { position: sticky; top: 47px; z-index: 2; background: Canvas; text-align: left; }
        th, td { padding: 11px; border: 1px solid #8884; vertical-align: top; }
        th:nth-child(1) { width: 15%; } th:nth-child(2) { width: 17%; }
        th:nth-child(3), th:nth-child(4), th:nth-child(5) { width: 22.66%; }
        .text { white-space: pre-wrap; line-height: 1.38; overflow-wrap: anywhere; }
        .truth { background: color-mix(in srgb, #36a269 9%, Canvas); }
        .issue { background: color-mix(in srgb, #d04a42 7%, Canvas); }
        audio { width: 100%; height: 34px; }
        details { margin-top: 7px; font-size: 12px; }
        summary { cursor: pointer; color: #777; }
        .badges { margin: 7px 0 5px; }
        .badge { display: inline-block; border-radius: 10px; padding: 2px 6px; margin: 0 4px 4px 0; font-size: 11px; }
        .bad { background: #d04a4228; color: #b4312b; }
        .warn { background: #d99b2428; color: #946200; }
        .good { background: #36a26928; color: #22794a; }
        .final-label { margin-top: 9px; padding-top: 7px; border-top: 1px dashed #8887; color: #777; font-size: 11px; font-weight: 650; text-transform: uppercase; }
        @media (max-width: 900px) { table { table-layout: auto; } th { position: static; } }
      </style>
    </head>
    <body>
      <header>
        <h1>Agent dictation eval</h1>
        <div>\(records.count) cases · \(issueCount) to review · ASR \(escapeHTML(header.asrModel)) · polish \(escapeHTML(header.polishModel))</div>
        <div class=muted>\(escapeHTML(header.audioSource ?? "unknown audio source"))</div>
        <div class=counts>
          \(badge("ASR mismatch: \(count("ASR mismatch"))"))
          \(badge("ASR unrecovered: \(count("ASR unrecovered"))"))
          \(badge("polish/normalizer miss: \(count("polish/normalizer miss"))"))
          \(badge("polish recovered: \(count("polish recovered"))"))
          \(badge("guard loss: \(count("guard loss"))"))
          \(badge("guard save: \(count("guard save"))"))
          \(badge("exact mismatch: \(count("exact mismatch"))"))
        </div>
      </header>
      <div class=toolbar>
        <button id=issues class=active>Review only</button>
        <button id=all>All cases</button>
        <select id=stratum>\(options)</select>
      </div>
      <table>
        <thead><tr><th>Case</th><th>Audio</th><th>ASR transcript</th><th>LLM polish</th><th>Ground truth</th></tr></thead>
        <tbody>\(rows)</tbody>
      </table>
      <script>
        const rows = [...document.querySelectorAll('tbody tr')];
        const issues = document.querySelector('#issues');
        const all = document.querySelector('#all');
        const stratum = document.querySelector('#stratum');
        let issuesOnly = true;
        function apply() {
          rows.forEach(row => row.hidden = (issuesOnly && row.dataset.issue !== '1') ||
            (stratum.value && row.dataset.stratum !== stratum.value));
          issues.classList.toggle('active', issuesOnly);
          all.classList.toggle('active', !issuesOnly);
        }
        issues.onclick = () => { issuesOnly = true; apply(); };
        all.onclick = () => { issuesOnly = false; apply(); };
        stratum.onchange = apply;
        apply();
      </script>
    </body>
    </html>
    """
}

do {
    let options = try parseOptions()
    let logURL = URL(fileURLWithPath: options.logPath!).standardizedFileURL
    let recordingDirectory = options.recordingDirectory.map {
        URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
    }
    let (header, records) = try decodeReport(at: logURL)
    let audioFiles = try loadAudioFiles(from: recordingDirectory)
    let outputURL = recordingDirectory?.appendingPathComponent("eval-report.html")
        ?? logURL.deletingLastPathComponent().appendingPathComponent("agent-eval-report.html")
    try renderHTML(header: header, records: records, audioFiles: audioFiles)
        .write(to: outputURL, atomically: true, encoding: .utf8)
    print("Eval report: \(outputURL.path)")
    if options.openAfterWriting {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [outputURL.path]
        try process.run()
    }
} catch {
    FileHandle.standardError.write(Data("render-agent-eval-report: \(error)\n".utf8))
    exit(1)
}
