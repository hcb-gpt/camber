import Foundation

@inline(__always)
private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func runDecodeTests() {
    do {
        let valid = Data(#"{"ok":true}"#.utf8)
        try ensureBootstrapActionOk(valid, action: "dismiss")
    } catch {
        fputs("FAIL: valid JSON unexpectedly threw: \(error)\n", stderr)
        exit(1)
    }

    var threwMalformed = false
    do {
        try ensureBootstrapActionOk(Data("not json".utf8), action: "dismiss")
    } catch {
        threwMalformed = true
        let message = String(describing: error)
        require(message.contains("Malformed dismiss response payload"), "malformed payload error message missing context")
    }
    require(threwMalformed, "invalid JSON must throw instead of silent success")
}

private func runTranscriptTests() {
    let merged = TranscriptParser.parse(
        """
        Chad Barlow: Need a bid update.
        Chad Barlow: Also send revised timeline.
        Malcolm Hetzer: We can do Friday.
        """
    )
    require(merged.count == 2, "consecutive same-speaker turns should merge into one bubble")
    require(merged[0].speaker == "Chad Barlow", "first merged speaker mismatch")
    require(merged[0].isOwnerSide, "owner-side detection should be true for Chad")
    require(merged[1].speaker == "Malcolm Hetzer", "second merged speaker mismatch")
    require(!merged[1].isOwnerSide, "non-owner speaker should not be owner side")

    let inline = TranscriptParser.parse("Malcolm Hetzer: Hello Zachary Sittler: Sounds good.")
    require(inline.count == 2, "inline speaker markers should parse into separate turns")
}

@main
struct IOSMicrotestsDecodeTranscript {
    static func main() {
        runDecodeTests()
        runTranscriptTests()
        print("PASS ios microtests: decode + transcript")
    }
}
