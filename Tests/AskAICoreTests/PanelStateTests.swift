import Testing
@testable import AskAICore

@Suite("Panel state machine")
struct PanelStateTests {

    @Test("idle -> loading -> success")
    func successPath() {
        let vm = PanelViewModel()
        #expect(vm.state == .idle)
        let id = vm.startLoading(selection: "photosynthesis")
        #expect(vm.state.isLoading)
        #expect(vm.finish(requestID: id, answer: "Plants make sugar from light."))
        #expect(vm.state == .success(selection: "photosynthesis",
                                     answer: "Plants make sugar from light."))
    }

    @Test("idle -> loading -> failure")
    func failurePath() {
        let vm = PanelViewModel()
        let id = vm.startLoading(selection: "photosynthesis")
        #expect(vm.fail(requestID: id, message: "Network offline"))
        #expect(vm.state == .failure(selection: "photosynthesis",
                                     message: "Network offline", retryable: true))
    }

    @Test("a second invocation makes the first one's result a no-op")
    func staleResultIsDropped() {
        let vm = PanelViewModel()
        let first = vm.startLoading(selection: "one")
        let second = vm.startLoading(selection: "two")
        #expect(first != second)

        // The slow first request lands after the second started.
        #expect(vm.finish(requestID: first, answer: "stale") == false)
        #expect(vm.state == .loading(selection: "two"))

        #expect(vm.finish(requestID: second, answer: "fresh"))
        #expect(vm.state == .success(selection: "two", answer: "fresh"))
    }

    @Test("a reply arriving after dismissal cannot reopen the panel")
    func resetInvalidatesInFlight() {
        let vm = PanelViewModel()
        let id = vm.startLoading(selection: "one")
        vm.reset()
        #expect(vm.state == .idle)
        #expect(vm.finish(requestID: id, answer: "late") == false)
        #expect(vm.state == .idle)
    }

    @Test("retry can recover the selection from a failure state")
    func failureRetainsSelection() {
        let vm = PanelViewModel()
        let id = vm.startLoading(selection: "mitochondria")
        vm.fail(requestID: id, message: "429")
        #expect(vm.state.selection == "mitochondria")
    }

    @Test("empty selection is terminal and carries no selection")
    func emptySelection() {
        let vm = PanelViewModel()
        vm.showEmptySelection()
        #expect(vm.state == .emptySelection)
        #expect(vm.state.selection == nil)
    }

    @Test("observers see every transition in order")
    func notifiesObserver() {
        let vm = PanelViewModel()
        var seen: [PanelState] = []
        vm.onChange = { seen.append($0) }
        let id = vm.startLoading(selection: "x")
        vm.finish(requestID: id, answer: "y")
        #expect(seen.count == 2)
        #expect(seen[0].isLoading)
        #expect(seen[1] == .success(selection: "x", answer: "y"))
    }
}
