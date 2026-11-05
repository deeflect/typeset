import Testing
@testable import MarcoCore

@Suite("CheckboxWriteBack")
struct CheckboxWriteBackTests {
    @Test func flipsUncheckedToChecked() {
        let text = "# Title\n\n- [ ] one\n- [ ] two\n"
        let result = CheckboxWriteBack.flip(fileText: text, blockStartLine: 2, itemLineOffset: 0, checked: true)
        #expect(result == "# Title\n\n- [x] one\n- [ ] two\n")
    }

    @Test func flipsCheckedToUnchecked() {
        let text = "- [x] done\n"
        let result = CheckboxWriteBack.flip(fileText: text, blockStartLine: 0, itemLineOffset: 0, checked: false)
        #expect(result == "- [ ] done\n")
    }

    @Test func preservesRestOfLine() {
        let text = "- [ ] **bold** item with `code` and text\n"
        let result = CheckboxWriteBack.flip(fileText: text, blockStartLine: 0, itemLineOffset: 0, checked: true)
        #expect(result == "- [x] **bold** item with `code` and text\n")
    }

    @Test func flipsExactlyTheTargetedItemAmongMany() {
        // A list with multiple task items at mixed nesting; toggling item N
        // must flip that line and leave every other byte untouched.
        let text = """
        - [ ] alpha
        - [x] bravo
          - [ ] bravo-child
        - [ ] charlie
        """
        // Toggle the nested "bravo-child" (body line 2) on.
        let result = CheckboxWriteBack.flip(fileText: text, blockStartLine: 0, itemLineOffset: 2, checked: true)
        #expect(result == """
        - [ ] alpha
        - [x] bravo
          - [x] bravo-child
        - [ ] charlie
        """)
    }

    @Test func handlesIndentedNestedItem() {
        let text = "- parent\n  - [ ] child\n"
        let result = CheckboxWriteBack.flip(fileText: text, blockStartLine: 0, itemLineOffset: 1, checked: true)
        #expect(result == "- parent\n  - [x] child\n")
    }

    @Test func handlesFrontmatterOffset() {
        let text = "---\ntitle: X\n---\n- [ ] item\n"
        // body (after frontmatter split) is "- [ ] item\n", so the item is
        // at body line 0.
        let result = CheckboxWriteBack.flip(fileText: text, blockStartLine: 0, itemLineOffset: 0, checked: true)
        #expect(result == "---\ntitle: X\n---\n- [x] item\n")
    }

    @Test func preservesLineEndingsAndBOM() {
        for newline in ["\r\n", "\r", "\n"] {
            let source = "\u{FEFF}- [ ] first\(newline)- [ ] second\(newline)"
            #expect(CheckboxWriteBack.flip(fileText: source, blockStartLine: 0, itemLineOffset: 1, checked: true)
                == "\u{FEFF}- [ ] first\(newline)- [x] second\(newline)")
            #expect(CheckboxWriteBack.flip(fileText: source, blockStartLine: 0, itemLineOffset: 0, checked: true)
                == "\u{FEFF}- [x] first\(newline)- [ ] second\(newline)")
        }
    }

    @Test func rejectsWhenAlreadyInTargetState() {
        let text = "- [x] done\n"
        let result = CheckboxWriteBack.flip(fileText: text, blockStartLine: 0, itemLineOffset: 0, checked: true)
        #expect(result == nil)
    }

    @Test func rejectsWhenLineIsNotACheckbox() {
        let text = "just a paragraph\n"
        let result = CheckboxWriteBack.flip(fileText: text, blockStartLine: 0, itemLineOffset: 0, checked: true)
        #expect(result == nil)
    }

    @Test func rejectsWhenLineIndexOutOfBounds() {
        let text = "- [ ] only line\n"
        let result = CheckboxWriteBack.flip(fileText: text, blockStartLine: 5, itemLineOffset: 0, checked: true)
        #expect(result == nil)
    }

    @Test func rejectsWhenFileChangedUnderneath() {
        // Simulates the guard: the line the caller *thinks* is at this
        // offset is no longer a checkbox line (e.g. the file was rewritten
        // by an agent between the click and the write).
        let text = "- [ ] one\nsomething else now\n"
        let result = CheckboxWriteBack.flip(fileText: text, blockStartLine: 1, itemLineOffset: 0, checked: true)
        #expect(result == nil)
    }

    @Test func rejectsNegativeOffsets() {
        let text = "- [ ] item\n"
        #expect(CheckboxWriteBack.flip(fileText: text, blockStartLine: -1, itemLineOffset: 0, checked: true) == nil)
        #expect(CheckboxWriteBack.flip(fileText: text, blockStartLine: 0, itemLineOffset: -1, checked: true) == nil)
    }
}
