import Testing

/// Holds each sleep until the test lets it end, so the timing is checked without waiting.
private final class Sleeps {
    private(set) var durations: [Duration] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []

    var pending: Int { waiting.count }

    func sleep(_ duration: Duration) async {
        durations.append(duration)
        await withCheckedContinuation { waiting.append($0) }
    }

    func endOldest() {
        waiting.removeFirst().resume()
    }
}

@Suite @MainActor
struct ActionFeedbackTests {
    /// Lets the feedback's own task run after a sleep ends or starts.
    private func settle(until done: () -> Bool) async {
        for _ in 0..<200 where !done() { await Task.yield() }
    }

    @Test func showsItsMessageForOneMomentAndTellsVoiceOver() async {
        let sleeps = Sleeps()
        var announced: [String] = []
        let feedback = ActionFeedback(announce: { announced.append($0) }, sleep: sleeps.sleep)
        #expect(!feedback.isShowing)

        feedback.show()
        #expect(feedback.message == "Copied")
        #expect(announced == ["Copied"])
        await settle { sleeps.pending == 1 }
        #expect(sleeps.durations == [.seconds(1.5)])

        sleeps.endOldest()
        await settle { !feedback.isShowing }
        #expect(feedback.message == nil)
    }

    @Test func showingAgainRestartsTheMoment() async {
        let sleeps = Sleeps()
        var announced: [String] = []
        let feedback = ActionFeedback(announce: { announced.append($0) }, sleep: sleeps.sleep)

        feedback.show()
        await settle { sleeps.pending == 1 }
        feedback.show("Link Copied")
        await settle { sleeps.pending == 2 }
        #expect(announced == ["Copied", "Link Copied"])

        // The first moment ends while the second runs: the mark stays.
        sleeps.endOldest()
        for _ in 0..<50 { await Task.yield() }
        #expect(feedback.message == "Link Copied")

        sleeps.endOldest()
        await settle { !feedback.isShowing }
        #expect(feedback.message == nil)
    }

    @Test func textLastsLongerThanATick() async {
        let sleeps = Sleeps()
        let feedback = ActionFeedback(duration: ActionFeedback.textDuration, announce: { _ in }, sleep: sleeps.sleep)
        feedback.show("2 Links Copied")
        await settle { sleeps.pending == 1 }
        #expect(sleeps.durations == [.seconds(2.5)])
        sleeps.endOldest()
        await settle { !feedback.isShowing }
    }

    @Test func linkMessagesCount() {
        #expect(ActionFeedback.linksCopied(1) == "Link Copied")
        #expect(ActionFeedback.linksCopied(3) == "3 Links Copied")
    }
}
