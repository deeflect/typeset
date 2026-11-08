import Testing
@testable import TypesetCore

@Suite("EditConflictMachine")
struct EditConflictStateTests {
    @Test func cleanExternalChangeReloadsSilently() {
        let result = EditConflictMachine.transition(state: .clean, event: .externalChange)
        #expect(result.state == .clean)
        #expect(result.action == .silentReload)
    }

    @Test func editingMakesStateDirty() {
        let result = EditConflictMachine.transition(state: .clean, event: .bufferEdited)
        #expect(result.state == .dirty)
        #expect(result.action == .none)
    }

    @Test func dirtyExternalChangeShowsBanner() {
        let result = EditConflictMachine.transition(state: .dirty, event: .externalChange)
        #expect(result.state == .conflictPending)
        #expect(result.action == .showConflictBanner)
    }

    @Test func keepMineReturnsToDirtyAndKeepsBuffer() {
        let result = EditConflictMachine.transition(state: .conflictPending, event: .keepMine)
        #expect(result.state == .dirty)
        #expect(result.action == .dismissBannerKeepBuffer)
    }

    @Test func takeTheirsReturnsToCleanAndReloadsBuffer() {
        let result = EditConflictMachine.transition(state: .conflictPending, event: .takeTheirs)
        #expect(result.state == .clean)
        #expect(result.action == .dismissBannerReloadBuffer)
    }

    @Test func savingSettlesDirtyBackToClean() {
        let result = EditConflictMachine.transition(state: .dirty, event: .bufferSettled)
        #expect(result.state == .clean)
        #expect(result.action == .none)
    }

    @Test func furtherEditsWhileConflictPendingDoNotDismissBanner() {
        let result = EditConflictMachine.transition(state: .conflictPending, event: .bufferEdited)
        #expect(result.state == .conflictPending)
        #expect(result.action == .none)
    }

    @Test func externalChangeWhileConflictPendingIsANoOp() {
        let result = EditConflictMachine.transition(state: .conflictPending, event: .externalChange)
        #expect(result.state == .conflictPending)
        #expect(result.action == .none)
    }
}
