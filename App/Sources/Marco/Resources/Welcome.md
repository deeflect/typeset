---
title: Welcome to Marco
subtitle: Preview.app for Markdown
version: 0.1.0
tags: [markdown, macOS, reading]
---

# Welcome to Marco

Marco opens a Markdown file the way Preview opens a PDF — **instantly**,
beautifully rendered, and ready to read. No sidebar to configure, no
account to make, no syntax to learn. Just your document, looking the way
it was always meant to look.

This page is written in Markdown. What you're reading *is* the format,
rendered by the same engine that will render your files.

## Typography that earns its place

Marco uses a hand-tuned **SF Pro** ramp so headings breathe and body text
sits at a comfortable reading measure — around seventy characters, the
width books have used for centuries. Long lines are tiring; Marco keeps
them honest.

You get the full range of inline styling: **bold** for weight, *italic*
for emphasis, ~~strikethrough~~ for second thoughts, `inline code` for the
literal, and [links](https://daringfireball.net/projects/markdown/) in the
system accent color. Relative links to other `.md` files open in place.

### Smaller headings converge toward the body

#### So the hierarchy stays legible

##### Without shouting

###### Down to the quietest level

## Code, highlighted and copyable

Fenced code blocks become cards — a subtle fill, a hairline border, and
horizontal scrolling contained *inside* the card so wide lines never push
your page around. Hover to reveal the language tag and a copy button that
morphs into a checkmark when it's done.

```swift
struct Block: Identifiable {
    let kind: BlockKind
    let rawText: String
    let contentHash: String

    var id: String { "\(contentHash)#\(ordinal)" }
}

func render(_ blocks: [Block]) -> some View {
    LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(blocks) { BlockView(block: $0) }
    }
}
```

Highlighting is computed off the main thread and cached, so scrolling a
thousand code blocks stays smooth.

```python
def fibonacci(n: int) -> int:
    a, b = 0, 1
    for _ in range(n):
        a, b = b, a + b
    return a
```

## Tables, aligned and alive

| Feature            | Status      | Ships in |
| ------------------ | :---------: | -------: |
| Block renderer     | Done        |     v1.0 |
| Live reload        | In progress |     v1.0 |
| Mermaid + KaTeX    | Planned     |     v1.1 |
| Folder mode        | Planned     |     v1.1 |

Header rows are emphasized, columns respect their alignment, and rows
highlight as you move the pointer across them. Wider tables scroll sideways
inside their own card instead of stretching the page.

## Lists, nested properly

- Reading-first, edit when you need to
- Live reload while your agent rewrites the file
  - Changed blocks pulse, once, softly
  - Scroll position anchors to the nearest heading
- Copy as rich text, export to PDF

1. Double-click a `.md` file in Finder
2. It opens, already rendered
3. Press `⌘W` and it's gone — weightless

### Task lists with real checkboxes

- [x] Parse Markdown into a stable block model
- [x] Build the custom block renderer
- [ ] Wire live reload
- [ ] Ship to the App Store

## Blockquotes carry a voice

> The moat is not features — it's that it looks and feels like Apple
> shipped it. Every decision is subordinated to two bars: visual quality
> and snappiness.
>
> > Nested quotes deepen the accent bar, so a reply inside a reply stays
> > visually distinct.

## Everything else, handled

Marco renders images with rounded corners and downsampled decode, resolves
frontmatter into the tidy chip at the top of this page, and draws a quiet
centered rule when a document changes subject:

---

That's the whole idea. Open a file and read it. When an agent rewrites it
next to you, watch the changes arrive without a flicker.

*Now open one of your own.*
