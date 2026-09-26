// UNCOMMITTED bench for #709's bundled-helper arm. Runs only when
// EvalRecordings/early-polish-709/requests.json exists. Never commit.
import Foundation
import XCTest

final class EarlyPolishHelperBench709: XCTestCase {
    private struct Item: Decodable {
        let id: String
        let pieces: [[[String: String]]]
        let tail: [[String: String]]?
        let whole: [[String: String]]
    }

    private let endpoint = URL(string: "http://127.0.0.1:8080/v1/chat/completions")!
    private let budget: TimeInterval = 30 * 60

    private func post(_ messages: [[String: String]]) async throws -> (String, Double) {
        var request = URLRequest(url: endpoint, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "mlx-community/Qwen3.5-4B-OptiQ-4bit",
            "messages": messages,
            "temperature": 0.3,
            "chat_template_kwargs": ["enable_thinking": false],
        ] as [String: Any])
        let started = Date()
        let (data, _) = try await URLSession.shared.data(for: request)
        let seconds = Date().timeIntervalSince(started)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = ((json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])
        return ((message?["content"] as? String) ?? "", seconds)
    }

    private func emit(_ id: String, _ arm: String, _ text: String, _ seconds: Double) {
        let line = try! JSONSerialization.data(withJSONObject: ["id": id, "arm": arm, "text": text, "secs": seconds])
        print("LVX709 " + String(decoding: line, as: UTF8.self))
    }

    func testReplay() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("EvalRecordings/early-polish-709/requests.json")
        guard let data = try? Data(contentsOf: file) else { throw XCTSkip("no request file") }
        let items = try JSONDecoder().decode([Item].self, from: data)
        // Wake the on-demand polishd test service and wait for its port.
        FileManager.default.createFile(atPath: "/Users/Shared/localvoxtral/run/mlxlm.want", contents: nil)
        var ready = false
        for _ in 0..<180 {
            if (try? await post([["role": "user", "content": "Ready."]])) != nil { ready = true; break }
            try await Task.sleep(for: .seconds(2))
        }
        XCTAssertTrue(ready, "polishd on 8080 never answered")
        guard ready else { return }
        let started = Date()
        for item in items {
            if Date().timeIntervalSince(started) > budget { print("LVX709 BUDGET"); break }
            for (index, piece) in item.pieces.enumerated() {
                let (text, secs) = try await post(piece)
                emit(item.id, "piece\(index)", text, secs)
            }
            if let tail = item.tail {
                let (text, secs) = try await post(tail)
                emit(item.id, "tail", text, secs)
            }
            for arm in ["whole-a", "whole-b"] {
                let (text, secs) = try await post(item.whole)
                emit(item.id, arm, text, secs)
            }
            // Keep the service's idle window open.
            FileManager.default.createFile(atPath: "/Users/Shared/localvoxtral/run/mlxlm.want", contents: nil)
        }
        print("LVX709 DONE")
    }
}
