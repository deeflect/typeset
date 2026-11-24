# CLI & Agent Hooks

## Installing the `typeset` CLI

`Scripts/typeset` opens Markdown files, folders (in Folder Mode), or piped stdin in Typeset:

```sh
sudo install -m 755 Scripts/typeset /usr/local/bin/typeset
```

Or symlink it into a directory already on your `PATH`:

```sh
mkdir -p ~/.local/bin
ln -sf "$PWD/Scripts/typeset" ~/.local/bin/typeset
```

Examples:

```sh
typeset README.md               # open a file
typeset .claude/                # open a folder with the Files sidebar
git diff --stat | typeset -     # pipe stdin to a temporary Markdown buffer
```

## Claude Code Hook Recipe

Open new or updated plan/report Markdown files in Typeset automatically when Claude Code writes them (add to `~/.claude/settings.json`):

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "jq -r '.tool_input.file_path // empty' | grep -E '\\.(md|mdx)$' | xargs -I{} typeset \"{}\""
          }
        ]
      }
    ]
  }
}
```
