#!/usr/bin/env python3
"""Verify Scripts/typeset argument handling without launching the GUI."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
CLI = ROOT / "Scripts/typeset"

assert os.access(CLI, os.X_OK), f"{CLI} must be executable"

help_res = subprocess.run([str(CLI), "--help"], capture_output=True, text=True)
assert help_res.returncode == 0
assert "Usage: typeset" in help_res.stdout

missing_res = subprocess.run([str(CLI), "/nonexistent/typeset-missing-file.md"], capture_output=True, text=True)
assert missing_res.returncode != 0
assert "No such file or directory" in missing_res.stderr

with tempfile.TemporaryDirectory(prefix="typeset-cli-check-") as directory:
    temp = Path(directory)
    bin_dir = temp / "bin"
    bin_dir.mkdir()
    log = temp / "open-args.txt"
    mock_open = bin_dir / "open"
    mock_open.write_text('#!/bin/sh\nprintf "<%s>\\n" "$@" > "$MOCK_OPEN_LOG"\n')
    mock_open.chmod(0o755)

    sample = temp / "note.md"
    sample.write_text("# Hi\n")

    env = os.environ.copy()
    env["PATH"] = f"{bin_dir}:{env['PATH']}"
    env["MOCK_OPEN_LOG"] = str(log)

    file_res = subprocess.run([str(CLI), str(sample)], env=env, capture_output=True, text=True)
    assert file_res.returncode == 0, file_res.stderr
    assert f"<{sample}>" in log.read_text()

    stdin_res = subprocess.run([str(CLI), "-"], input="# From stdin\n", env=env, capture_output=True, text=True)
    assert stdin_res.returncode == 0, stdin_res.stderr
    logged = [line.strip("<>") for line in log.read_text().splitlines()]
    piped_path = Path(logged[-1])
    assert piped_path.name == "stdin.md" and piped_path.read_text() == "# From stdin\n"
    piped_path.unlink(missing_ok=True)
    piped_path.parent.rmdir()

print("cli script checks passed")
