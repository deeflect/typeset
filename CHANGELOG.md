# Changelog

All notable changes to Typeset.md. Versions follow [Semantic Versioning](https://semver.org).

## [1.1.0] - 2026-11-24

Diagrams and math, drawn right on your Mac with no network access.

### Added

- Mermaid diagrams: flowchart, sequence, state, ER, class, pie, git graph, journey and architecture. They are drawn natively and offline. If a diagram can't be drawn, you see its source instead.
- LaTeX math: inline `$…$`, display `$$…$$`, and `math`, `latex` or `tex` code blocks. Formulas sit on the text baseline.
- Quick Look thumbnails: Finder icons for .md files now show the first page.
- A `typeset` command for Terminal: open a file, a folder, or piped text with `git diff --stat | typeset -`. See [CLI and agent hooks](https://github.com/deeflect/typeset/blob/main/docs/cli-and-agents.md) for a Claude Code hook that opens plans as they are written.

### Changed

- Large files open and reload faster: each document is parsed once, footnotes are found in a single pass, and the outline is cached.

## [1.0.1] - 2026-11-14

First public release. Free, open source under AGPL-3.0, signed and notarized.

### Added

- Live reload in place: when the file changes, only the changed part redraws and your place stays put.
- Change markers: a blue bar shows what changed since you last opened the file. <kbd>⌥⌘↓</kbd> jumps to the next change.
- Copy for agent: <kbd>⇧⌥⌘C</kbd> copies a passage with its file path and line numbers.
- GitHub-flavoured Markdown: tables, highlighted code, alerts, footnotes, task lists, frontmatter and README HTML. Light and dark follow your Mac.
- Quick Look: press <kbd>Space</kbd> on a .md file in Finder to preview it.
- Folders: <kbd>⇧⌘O</kbd> opens a folder, <kbd>⌘K</kbd> jumps to any file in it by name.
- Export as PDF (<kbd>⇧⌘E</kbd>), print, or Rich Text for Pages, Word and Google Docs.
- Edit the source with <kbd>⌘E</kbd>. Ticking a task in the reader saves it to the file.
- New from Clipboard opens whatever Markdown you copied.
- No account, no analytics, no network access.

[1.1.0]: https://github.com/deeflect/typeset/releases/tag/v1.1.0
[1.0.1]: https://github.com/deeflect/typeset/releases/tag/v1.0.1
