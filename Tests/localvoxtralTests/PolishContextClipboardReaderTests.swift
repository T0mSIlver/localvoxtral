import AppKit
import XCTest
@testable import localvoxtral

@MainActor
final class PolishContextClipboardReaderTests: XCTestCase {
    // MARK: - Sensitive-type skips

    func testConcealedTypeReturnsNil() {
        let stub = PasteboardStub(string: "hunter2", types: [.nsPasteboardConcealed, .string])
        XCTAssertNil(PolishContextClipboardReader.readClipboardContext(from: stub))
    }

    func testTransientTypeReturnsNil() {
        let stub = PasteboardStub(string: "one-shot", types: [.nsPasteboardTransient, .string])
        XCTAssertNil(PolishContextClipboardReader.readClipboardContext(from: stub))
    }

    // MARK: - Empty / missing string

    func testNoStringReturnsNil() {
        let stub = PasteboardStub(string: nil)
        XCTAssertNil(PolishContextClipboardReader.readClipboardContext(from: stub))
    }

    func testEmptyStringReturnsNil() {
        let stub = PasteboardStub(string: "")
        XCTAssertNil(PolishContextClipboardReader.readClipboardContext(from: stub))
    }

    func testWhitespaceOnlyStringReturnsNil() {
        let stub = PasteboardStub(string: "   \n\t  ")
        XCTAssertNil(PolishContextClipboardReader.readClipboardContext(from: stub))
    }

    // MARK: - Capping

    func testCapsExcerptAtLimitAndReportsOriginalCount() {
        let raw = String(repeating: "a", count: 2500)
        let stub = PasteboardStub(string: raw)
        let context = PolishContextClipboardReader.readClipboardContext(from: stub)
        XCTAssertEqual(context?.excerpt.count, 2000)
        XCTAssertEqual(context?.originalCharacterCount, 2500)
        XCTAssertEqual(context?.provenanceSummary, "clipboard:2000/2500ch")
    }

    func testUncappedExcerptReportsEqualCounts() {
        let stub = PasteboardStub(string: "abc")
        let context = PolishContextClipboardReader.readClipboardContext(from: stub)
        XCTAssertEqual(context?.excerpt, "abc")
        XCTAssertEqual(context?.originalCharacterCount, 3)
        XCTAssertEqual(context?.provenanceSummary, "clipboard:3ch")
    }

    // MARK: - Control-character stripping

    func testStripsControlCharsButKeepsNewlineAndTab() {
        // NUL and bell dropped; tab and newline preserved.
        let stub = PasteboardStub(string: "a\u{0000}b\tc\nd\u{0007}e")
        let context = PolishContextClipboardReader.readClipboardContext(from: stub)
        XCTAssertEqual(context?.excerpt, "ab\tc\nde")
        XCTAssertEqual(context?.originalCharacterCount, 7)
    }

    // MARK: - Loopback-endpoint privacy gate

    func testLoopbackEndpointsAreLocal() {
        let loopback = [
            "http://127.0.0.1:8472/v1/chat/completions",  // managed polishd
            "http://localhost:8080/v1/chat/completions",
            "https://LOCALHOST/v1/chat/completions",      // case-insensitive
            "http://[::1]:8080/v1/chat/completions",      // IPv6 loopback literal
        ]
        for urlString in loopback {
            let url = URL(string: urlString)!
            XCTAssertTrue(
                PolishContextClipboardReader.isLoopbackEndpoint(url),
                "should be loopback: \(urlString)"
            )
        }
    }

    func testNonLoopbackEndpointsAreNotLocal() {
        let remote = [
            "https://example.com/v1/chat/completions",       // cloud provider
            "http://192.168.1.10:8080/v1/chat/completions",  // LAN IP: off-Mac
            "https://api.openai.com/v1/chat/completions",
            "http://127.0.0.1.evil.com/v1",                  // loopback-prefixed host
        ]
        for urlString in remote {
            let url = URL(string: urlString)!
            XCTAssertFalse(
                PolishContextClipboardReader.isLoopbackEndpoint(url),
                "should NOT be loopback: \(urlString)"
            )
        }
    }

    func testHostlessEndpointIsNotLocal() {
        // No authority at all: URL.host is nil (a file URL's empty authority
        // has come back as nil or "" across Foundation versions — both fail
        // the gate, but this pins the nil-host branch deterministically).
        let url = URL(string: "unix:/var/run/polishd.sock")!
        XCTAssertNil(url.host)
        XCTAssertFalse(PolishContextClipboardReader.isLoopbackEndpoint(url))
    }

    // MARK: - Leak guard

    /// A verbatim clipboard echo (>= 24 normalized chars, absent from the
    /// pre-polish text) is detected, and the reported length covers the whole
    /// contiguous leaked run.
    func testVerbatimEchoDetected() {
        let leaked = PolishContextClipboardReader.detectClipboardLeak(
            polished: "note: The quarterly report shows revenue increased by twelve percent",
            original: "add a note about the meeting",
            excerpt: "The quarterly report shows revenue increased by twelve percent across all regions"
        )
        XCTAssertEqual(
            leaked,
            "The quarterly report shows revenue increased by twelve percent".count
        )
    }

    /// Excerpt content that ALSO appears in the pre-polish working text is the
    /// user's own dictation, never a leak.
    func testExcerptContentAlreadyInOriginalIsNotALeak() {
        XCTAssertNil(
            PolishContextClipboardReader.detectClipboardLeak(
                polished: "The quarterly report shows revenue increased.",
                original: "The quarterly report shows revenue increased",
                excerpt: "The quarterly report shows revenue increased by twelve percent"
            )
        )
    }

    /// Short overlaps (below the 24-char threshold) never trip the guard —
    /// the code-like tokens the context legitimately grounds stay under it.
    func testShortOverlapBelowThresholdIsNotALeak() {
        XCTAssertNil(
            PolishContextClipboardReader.detectClipboardLeak(
                polished: "open UserSessionMgr.swift now",
                original: "open user session mgr file now",
                excerpt: "UserSessionMgr.swift plus unrelated clipboard content here"
            )
        )
    }

    /// Re-casing cannot hide a leak: an echoed clipboard prose line the model
    /// returns in a different case (title-case heading -> sentence case) is
    /// still detected — the scan case-folds all three texts consistently.
    func testRecasedEchoStillDetected() {
        XCTAssertNotNil(
            PolishContextClipboardReader.detectClipboardLeak(
                polished: "quarterly results: revenue increased by twelve percent",
                original: "add a note about the meeting",
                excerpt: "QUARTERLY RESULTS: Revenue Increased By Twelve Percent"
            )
        )
    }

    /// Case-folding applies to the pre-polish text too: content the user
    /// DICTATED that the model legitimately re-cases (and that also sits on
    /// the clipboard) is never a leak — the folded original contains it.
    func testRecasedOriginalContentIsNotALeak() {
        XCTAssertNil(
            PolishContextClipboardReader.detectClipboardLeak(
                polished: "The Quarterly Report Shows Revenue Increased.",
                original: "the quarterly report shows revenue increased",
                excerpt: "the quarterly report shows revenue increased by twelve percent"
            )
        )
    }

    /// Reflowed whitespace cannot hide a leak: the excerpt's newlines and the
    /// output's spaces normalize to the same form.
    func testWhitespaceReflowStillDetected() {
        XCTAssertNotNil(
            PolishContextClipboardReader.detectClipboardLeak(
                polished: "summary: please review the attached deployment checklist before Friday",
                original: "write a summary",
                excerpt: "please review the attached\ndeployment checklist\nbefore Friday"
            )
        )
    }

    /// THE grounding use case must survive with NO exemptions (stack
    /// layering: sanctioned pairs only exist one PR up): clipboard holds the
    /// exact identifier, the model inserts it. Code-like entities recognized
    /// in the excerpt by the token guard's own recognizer are intrinsically
    /// exempt — they are exactly what grounding is supposed to insert.
    func testCodeEntityGroundingIsNotALeak() {
        XCTAssertNil(
            PolishContextClipboardReader.detectClipboardLeak(
                polished: "Fix UserSessionManager.swift",
                original: "fix the user session manager",
                excerpt: "UserSessionManager.swift"
            )
        )
    }

    /// Intrinsic entity exemption is length-independent: a very long dotted
    /// filename inserted from grounding never trips the guard.
    func testLongCodeEntityGroundingIsNotALeak() {
        let entity = "VeryLongExplicitlyGroundedIdentifierName.swift"
        XCTAssertNil(
            PolishContextClipboardReader.detectClipboardLeak(
                polished: "open \(entity) and fix the import",
                original: "open very long explicitly grounded identifier name.swift and fix the import",
                excerpt: entity
            )
        )
    }

    /// Entity masking is a BOUNDARY, not an absence: a code-like entity
    /// embedded in a longer echoed prose line must not smuggle the
    /// surrounding prose through — the prose on either side of the mask is
    /// still scanned and still detected.
    func testEntityInsideEchoedProseLineStillDetected() {
        XCTAssertNotNil(
            PolishContextClipboardReader.detectClipboardLeak(
                polished: "note: error in UserSessionManager.swift at line 42 please retry now",
                original: "check the logs",
                excerpt: "error in UserSessionManager.swift at line 42 please retry now"
            )
        )
    }

    /// The explicit exemptions parameter (sanctioned rewrites, one PR up)
    /// masks arbitrary runs — including prose the intrinsic entity exemption
    /// would never cover — while the same run without the exemption is a leak.
    func testExplicitExemptionMasksProseRun() {
        let run = "please review the attached deployment checklist"
        XCTAssertNil(
            PolishContextClipboardReader.detectClipboardLeak(
                polished: "summary: \(run)",
                original: "write a summary",
                excerpt: "reminder: \(run) before Friday",
                exemptions: [run]
            )
        )
        XCTAssertNotNil(
            PolishContextClipboardReader.detectClipboardLeak(
                polished: "summary: \(run)",
                original: "write a summary",
                excerpt: "reminder: \(run) before Friday"
            )
        )
    }

    // MARK: - Provenance summary formatting

    func testProvenanceSummaryFormats() {
        XCTAssertEqual(
            PolishClipboardContext(excerpt: "abcd", originalCharacterCount: 4).provenanceSummary,
            "clipboard:4ch"
        )
        XCTAssertEqual(
            PolishClipboardContext(
                excerpt: String(repeating: "a", count: 2000),
                originalCharacterCount: 5321
            ).provenanceSummary,
            "clipboard:2000/5321ch"
        )
    }
}

/// Shared pasteboard stub with call counters. Used by the reader unit tests and
/// the view-model clipboard-context tests (`PolishTokenGuardTests.swift`), so
/// the "never read when off" privacy assertion can inspect the call counts.
@MainActor
final class PasteboardStub: PasteboardReading {
    var stubbedTypes: [NSPasteboard.PasteboardType]?
    var stubbedString: String?
    private(set) var typesCallCount = 0
    private(set) var stringCallCount = 0

    init(string: String? = nil, types: [NSPasteboard.PasteboardType]? = nil) {
        self.stubbedString = string
        self.stubbedTypes = types
    }

    func types() -> [NSPasteboard.PasteboardType]? {
        typesCallCount += 1
        return stubbedTypes
    }

    func string() -> String? {
        stringCallCount += 1
        return stubbedString
    }
}
