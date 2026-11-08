import Testing
import Foundation
@testable import TypesetCore

struct MDXScannerTests {

    static let body = """
    import { Callout,
      Chart } from './components'
    export const meta = {
      title: 'x',
    }

    # Hello {props.name}

    <Callout type="warn" title={`Heads up`}>
    Children are **markdown**.

    <Tabs.Item label="a">
    Nested
    </Tabs.Item>
    </Callout>

    <Chart
      data={[1, 2]}
    />

    <details>
    <summary>HTML stays HTML</summary>
    </details>

    ```jsx
    <Fake />
    ```

    <Open>
    never closed

    <Tab>inline</Tab>
    """

    @Test func scansNodeKinds() {
        let nodes = MDXScanner.scan(Self.body)
        // MDX ends ESM at a blank line, so import + export without one is a single node.
        #expect(nodes.map(\.kind) == [.esm, .jsxBlock, .jsxBlock, .jsxSelfClosing])
        #expect(nodes[0].lines == 0...4)
        #expect(nodes[1].name == "Callout")
        #expect(nodes[1].attributes == "type=\"warn\" title={`Heads up`}")
        #expect(nodes[1].lines == 8...8)
        #expect(nodes[1].closingLine == 14)
        #expect(nodes[1].childrenLines == 9..<14)
        #expect(nodes[2].name == "Tabs.Item")
        #expect(nodes[2].closingLine == 13)
        #expect(nodes[3].name == "Chart")
        #expect(nodes[3].attributes == "data={[1, 2]}")
        #expect(nodes[3].lines == 16...18)
    }

    @Test func parserMasksTagsAndKeepsChildrenAsMarkdown() {
        let blocks = MarkdownParser.parse(Self.body, mdx: true)
        #expect(!blocks.contains { $0.rawText.hasPrefix("import") || $0.rawText.hasPrefix("export") })
        #expect(blocks.contains { $0.kind == .htmlBlock && $0.rawText.hasPrefix("<Callout") && $0.startLine == 8 })
        #expect(blocks.contains { $0.kind == .paragraph && $0.rawText == "Children are **markdown**." })
        #expect(blocks.contains { $0.kind == .htmlBlock && $0.rawText.hasPrefix("<details>") })
        #expect(blocks.map(\.startLine) == blocks.map(\.startLine).sorted())
        #expect(blocks.map(\.ordinal) == Array(0..<blocks.count))
        // Without the flag the same text parses exactly as before.
        #expect(MarkdownParser.parse(Self.body) == MarkdownParser.parse(Self.body, mdx: false))
        #expect(MarkdownParser.parse(Self.body).contains { $0.rawText.hasPrefix("import") })
    }

    @Test func inlineExpressions() {
        let text = "Hi {props.name}, {a {b}} and {unclosed"
        #expect(MDXScanner.inlineExpressions(in: text).map { String(text[$0]) } == ["{props.name}", "{a {b}}"])
        #expect(MDXScanner.inlineExpressions(in: "no braces").isEmpty)
    }

    @Test func multilineAttributesKeepQuoteAndBraceState() {
        let body = """
        <Callout title="first
        > second" data={{ value:
          1 }}>
        Child
        </Callout>
        """
        let nodes = MDXScanner.scan(body)
        #expect(nodes.count == 1)
        #expect(nodes.first?.kind == .jsxBlock)
        #expect(nodes.first?.attributes == "title=\"first\n> second\" data={{ value:\n  1 }}")
        #expect(nodes.first?.closingLine == 4)
    }

    @Test func nestedSameNameIgnoresFencedCloser() {
        let body = """
        <Callout>
        <Callout>
        ```mdx
        </Callout>
        ```
        </Callout>
        </Callout>
        """
        let nodes = MDXScanner.scan(body)
        #expect(nodes.map(\.closingLine) == [6, 5])
        #expect(MDXScanner.masked(body, nodes: nodes) == "\n\n```mdx\n</Callout>\n```\n\n")
    }

    @Test func malformedLookaheadsScaleWithInput() {
        func duration(_ count: Int) -> TimeInterval {
            let body = Array(repeating: "<Open>\n", count: count).joined() + "plain text"
            let start = Date()
            #expect(MDXScanner.scan(body).isEmpty)
            return Date().timeIntervalSince(start)
        }
        let small = duration(1_000)
        let large = duration(8_000)
        #expect(large < max(1, small * 16))

        let unfinished = Array(repeating: "<Open>\n", count: 8_000).joined() + "plain text"
        #expect(MDXScanner.masked(unfinished, nodes: MDXScanner.scan(unfinished)) == unfinished)

        let attributes = "<Open title=\"unfinished\n" + Array(repeating: "still open\n", count: 8_000).joined()
        let attributeStart = Date()
        #expect(MDXScanner.scan(attributes).isEmpty)
        #expect(Date().timeIntervalSince(attributeStart) < 1)

        let esm = Array(repeating: "import {\n\n", count: 8_000).joined() + "plain text"
        let start = Date()
        #expect(MDXScanner.scan(esm).isEmpty)
        #expect(Date().timeIntervalSince(start) < 1)
    }
}
