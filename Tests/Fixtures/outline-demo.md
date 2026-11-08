# Typeset Engine Guide

Typeset renders each Markdown **block** as its own SwiftUI view. This guide walks
the block pipeline from bytes on disk to pixels on screen, and back again when
an agent rewrites the file underneath you.

## Parsing

The parser turns file bytes into a `[Block]` value model. Every block carries a
content hash so the differ can tell an untouched block from a changed one.

### The Block model

A block is the smallest unit the renderer reasons about. Splitting the document
into blocks is what lets Typeset reuse an unchanged block across a live reload.

- Each block hashes its own raw text.
- A stable identity keeps a block's view alive across reloads.
- Inserting a block never re-identifies the blocks around it.

### Incremental reparse

On reload, only the changed region is reparsed. Blocks far from the edit keep
their identity, so their views are never rebuilt.

## Rendering

One view per block, inside a `LazyVStack`, is what keeps a million-line file
scrolling smoothly. Off-screen blocks are never built.

### Inline text

Inline styling (bold, italic, links, inline code) is applied per block with
`AttributedString`, so selection and accessibility come for free.

```swift
// One view per block keeps rendering incremental.
func render(_ block: Block) -> some View {
    BlockView(block: block)
}
```

### Code blocks

A code block is highlighted off the main actor and cached by content hash, so a
reload never re-highlights an unchanged block.

## Live reload

When the file changes on disk, Typeset diffs the new blocks against the old ones
and re-renders only what changed. A changed block gets a one-time pulse.

- A clean editor takes the disk version silently.
- A dirty editor surfaces a non-modal conflict banner.
- Either way the block diff drives the update.

## Navigation

A relative link opens the target block set in the same window, with back and
forward history — reading a docs folder feels like browsing a small site.
