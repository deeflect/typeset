# Structure torture test

Exercises the six cmark-gfm drift cases the M1 architecture review flagged
against the old hand-rolled `BlockParsing.swift` line scanners.

## 1. List item with a nested paragraph and fenced code block

- First item, a plain paragraph.

  ```swift
  func greet(_ name: String) -> String {
      "Hello, \(name)!"
  }
  ```

  A second paragraph in the same item.

- Second item, no nested content.

## 2. Loose vs. tight lists

A tight list (no blank lines between items):

- one
- two
- three

A loose list (blank line between items):

- one

- two

- three

## 3. Ordered list start index and renumbering

Starts at 10, counts up:

10. ten
11. eleven
12. twelve

All items marked `1.` still render as `1.`, `2.`, `3.`:

1. alpha
1. bravo
1. charlie

## 4. Pipe inside a code span in a table cell

| Expression   | Result |
| ------------ | ------ |
| `a \| b`     | union  |
| `x[i \| j]`  | slice  |

## 5. Blockquote children: heading, nested list, nested code block

> # A heading inside a quote
>
> - a quoted list item
>
>   ```text
>   code fenced inside a quoted list item
>   ```
>
> A quoted paragraph after the list.
>
> > A nested quote one level deeper.

## 6. Heading text that legitimately ends in "#"

# C#

## C++ and C#

### Filenames like `README#` stay intact too
