import Foundation
import Testing
@testable import TypesetCore

struct ScrollAnchorTests {

    private func paragraph(_ text: String, ordinal: Int) -> Block {
        Block(kind: .paragraph, rawText: text, ordinal: ordinal, startLine: ordinal * 2)
    }

    private func heading(_ text: String, level: Int, ordinal: Int) -> Block {
        Block(kind: .heading(level: level), rawText: text, ordinal: ordinal, startLine: ordinal * 2)
    }

    @Test func anchorsToTheViewedBlockWhenItIsUnchanged() {
        let old = Block.assigningOccurrenceIndices(to: [
            paragraph("P0", ordinal: 0),
            paragraph("P1", ordinal: 1),
            paragraph("P2", ordinal: 2),
        ])
        // Edit happens far below the viewport; block at index 1 (the one
        // the viewport is anchored to) is unchanged.
        let new = old
        let changes = old.map { BlockChange.unchanged($0) }
        let anchor = ScrollAnchor.selectAnchor(oldBlocks: old, changes: changes, anchorIndex: 1)
        #expect(anchor == old[1].id)
        _ = new
    }

    @Test func fallsBackToNearestUnchangedBlockWhenViewedBlockWasEdited() {
        let old = Block.assigningOccurrenceIndices(to: [
            paragraph("P0", ordinal: 0),
            paragraph("P1", ordinal: 1),
            paragraph("P2", ordinal: 2),
        ])
        let newP1 = paragraph("P1 EDITED", ordinal: 1)
        let changes: [BlockChange] = [
            .unchanged(old[0]),
            .reloaded(old: old[1], new: newP1),
            .unchanged(old[2]),
        ]
        // Viewport was anchored to the edited block (index 1) — nearest
        // unchanged is index 0 (searched upward first).
        let anchor = ScrollAnchor.selectAnchor(oldBlocks: old, changes: changes, anchorIndex: 1)
        #expect(anchor == old[0].id)
    }

    @Test func prefersNearbyHeadingOverPlainParagraph() {
        let old = Block.assigningOccurrenceIndices(to: [
            heading("# H", level: 1, ordinal: 0),
            paragraph("P1", ordinal: 1),
            paragraph("P2", ordinal: 2),
        ])
        let changes = old.map { BlockChange.unchanged($0) }
        // Anchored to P2 (index 2); nearest unchanged upward search first
        // hits P1 (index 1), but a heading is within the 2-position
        // window above it, so the heading should win.
        let anchor = ScrollAnchor.selectAnchor(oldBlocks: old, changes: changes, anchorIndex: 2)
        #expect(anchor == old[0].id)
    }

    @Test func returnsNilWhenNoUnchangedBlockExistsNearby() {
        let old = Block.assigningOccurrenceIndices(to: [paragraph("P0", ordinal: 0)])
        let changes: [BlockChange] = [.deleted(old[0])]
        let anchor = ScrollAnchor.selectAnchor(oldBlocks: old, changes: changes, anchorIndex: 0)
        #expect(anchor == nil)
    }

    @Test func changeEntirelyBelowViewportLeavesAnchorAtSameBlock() {
        let old = Block.assigningOccurrenceIndices(to: [
            paragraph("P0", ordinal: 0),
            paragraph("P1", ordinal: 1),
            paragraph("P2", ordinal: 2),
            paragraph("P3", ordinal: 3),
        ])
        let newP3 = paragraph("P3 EDITED", ordinal: 3)
        let changes: [BlockChange] = [
            .unchanged(old[0]),
            .unchanged(old[1]),
            .unchanged(old[2]),
            .reloaded(old: old[3], new: newP3),
        ]
        // Viewport anchored at index 0 (top of doc); the edit is entirely
        // below — anchor should stay exactly where it was.
        let anchor = ScrollAnchor.selectAnchor(oldBlocks: old, changes: changes, anchorIndex: 0)
        #expect(anchor == old[0].id)
    }
}
