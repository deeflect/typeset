# Wrapping & placeholders

A stress fixture for multi-line layout: long blockquotes, long table cells,
and the graceful image placeholder.

> This is a deliberately long blockquote that must wrap across several lines
> instead of truncating with an ellipsis. It runs well past the reading
> measure so we can be certain the blockquote lays out multi-line text
> correctly, with the accent bar spanning the full height of the wrapped
> paragraph rather than clipping to a single line.
>
> > A nested quote, also long enough to wrap, should deepen its accent bar
> > while still wrapping every line of its text without truncation.

| Column | Description |
| ------ | ----------- |
| Wrapping | This cell holds a long description that should wrap onto multiple lines within its column — or scroll if the table is too wide — but it must never be silently truncated with an ellipsis in the middle of a word. |
| Short | Fine. |
| Alignment | Cells keep their column alignment even after wrapping to several lines of text. |

A missing image must render a visible, graceful placeholder — not a blank
gap:

![Diagram of the render pipeline (file intentionally absent)](does-not-exist.png)
