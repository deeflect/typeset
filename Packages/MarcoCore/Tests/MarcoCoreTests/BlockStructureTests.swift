import Testing
@testable import MarcoCore

/// Covers the six cmark-gfm drift cases the M1 architecture review flagged
/// against the old hand-rolled line scanners in `BlockParsing.swift`
/// (App target): code/paragraphs nested inside list items, loose vs tight
/// lists, ordered-list start/renumbering, pipes inside table code spans,
/// blockquote children, and heading text that legitimately ends in `#`.
struct BlockStructureTests {

    // MARK: 1. List item containing a fenced code block (and a paragraph)

    @Test func listItemContainsFencedCodeBlockAsANestedChild() {
        let raw = """
        - item one

          ```swift
          let x = 1
          ```

        - item two
        """
        let list = BlockStructure.list(raw)
        #expect(list?.items.count == 2)

        let first = list?.items[0]
        #expect(first?.children.count == 2)
        if case .paragraph(let text) = first?.children[0].kind {
            #expect(text == "item one")
        } else {
            Issue.record("expected first child to be a paragraph")
        }
        if case .codeBlock(let language, let fenced) = first?.children[1].kind {
            #expect(language == "swift")
            #expect(fenced.contains("let x = 1"))
        } else {
            Issue.record("expected second child to be a nested code block")
        }
    }

    // MARK: 2. Loose vs tight lists

    @Test func tightListIsNotLoose() {
        let raw = "- a\n- b\n"
        #expect(BlockStructure.list(raw)?.isLoose == false)
    }

    @Test func blankLineBetweenItemsMakesTheListLoose() {
        let raw = "- a\n\n- b\n"
        #expect(BlockStructure.list(raw)?.isLoose == true)
    }

    @Test func blankLineBetweenBlocksWithinOneItemMakesTheWholeListLoose() {
        // Same source that exercises drift case 1 above is also loose,
        // because of the blank line inside "item one" before its code
        // fence.
        let raw = """
        - item one

          ```swift
          let x = 1
          ```

        - item two
        """
        #expect(BlockStructure.list(raw)?.isLoose == true)
    }

    // MARK: 3. Ordered list start index + renumbering

    @Test func orderedListPreservesItsStartIndex() {
        let raw = "10. ten\n11. eleven\n"
        let list = BlockStructure.list(raw)
        #expect(list?.isOrdered == true)
        #expect(list?.start == 10)
        #expect(list?.items.count == 2)
    }

    @Test func orderedListWithRepeatedMarkersRenumbersFromStart() {
        // "1. / 1. / 1." is valid CommonMark: display numbering counts up
        // from `start`, it doesn't echo the literal (identical) markers.
        let raw = "1. a\n1. b\n1. c\n"
        let list = BlockStructure.list(raw)
        #expect(list?.start == 1)
        #expect(list?.items.count == 3)
        // The model doesn't store a per-item literal number at all — the
        // view computes displayed numbers as `start + index` — so there's
        // nothing here that could show "1. 1. 1.".
    }

    // MARK: 4. Pipe inside a code span must not split a table cell

    @Test func pipeInsideCodeSpanDoesNotSplitATableCell() {
        let raw = """
        | A | B |
        | - | - |
        | `a\\|b` | x |
        """
        let table = BlockStructure.table(raw)
        #expect(table?.header == ["A", "B"])
        #expect(table?.rows.first == ["`a|b`", "x"])
    }

    // MARK: 5. Blockquote children: heading, nested list, nested code block

    @Test func quoteContainsAHeadingChild() {
        let raw = "> # Heading\n"
        let quote = BlockStructure.quote(raw)
        #expect(quote?.children.count == 1)
        if case .heading(let level, let text) = quote?.children.first?.kind {
            #expect(level == 1)
            #expect(text == "Heading")
        } else {
            Issue.record("expected a heading child")
        }
    }

    @Test func quoteContainsAListContainingACodeBlock() {
        let raw = """
        > - a
        >
        >   ```
        >   code
        >   ```
        """
        let quote = BlockStructure.quote(raw)
        #expect(quote?.children.count == 1)
        guard case .list(let list) = quote?.children.first?.kind else {
            Issue.record("expected the quote's only child to be a list")
            return
        }
        #expect(list.items.count == 1)
        let itemChildren = list.items[0].children
        #expect(itemChildren.contains { if case .codeBlock = $0.kind { return true } else { return false } })
    }

    // MARK: 6. Heading text that legitimately ends in "#"

    @Test func headingTextEndingInHashIsNotStripped() {
        #expect(BlockStructure.headingText("# C#") == "C#")
    }

    @Test func softLineBreakInAMultiLineSetextHeadingIsPreserved() {
        // Regression: reconstructing inline text by joining each inline
        // child's own `.format()` drops the separator a soft break would
        // otherwise contribute (it's only emitted when the formatter walks
        // a whole subtree in sequence), running adjacent words together
        // ("One" + "two" -> "Onetwo"). A setext heading is the one heading
        // form that can span multiple source lines.
        #expect(BlockStructure.headingText("One\ntwo\n===") == "One\ntwo")
    }

    @Test func softLineBreakInAMultiLineListItemParagraphIsPreserved() {
        let list = BlockStructure.list("- one\n  two\n")
        guard case .paragraph(let text) = list?.items.first?.children.first?.kind else {
            Issue.record("expected a paragraph child")
            return
        }
        // The embedded "\n" (rather than the words running together) is
        // what `InlineMarkdown.normalizeSoftBreaks` (App target) expects
        // and collapses to a space when rendering.
        #expect(text == "one\ntwo")
    }

    @Test func atxClosingSequenceIsStillDropped() {
        // "## Title ##" is the ATX closing-sequence form; the trailing
        // "##" is markup, not part of the text, so it should still go away
        // (this comes for free from resolving text via the parsed inline
        // children rather than raw trailing-`#` stripping).
        #expect(BlockStructure.headingText("## Title ##") == "Title")
    }
}
