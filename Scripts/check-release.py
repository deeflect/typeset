#!/usr/bin/env python3
"""Check release command paths without Xcode, accounts, or file writes in the repo."""
import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent


with tempfile.TemporaryDirectory(prefix="typeset-release-check-") as directory:
    temporary = Path(directory)
    bin_dir = temporary / "bin"
    bin_dir.mkdir()
    for name, body in {
        "security": '#!/bin/sh\n[ "${MOCK_CERTS:-}" = none ] || echo \'1) HASH "Developer ID Application: Example (ABCDE12345)"\'\n',
        "xcodegen": '#!/bin/sh\nprintf "xcodegen\\n" >> "$MOCK_LOG"\n',
        "xcodebuild": '#!/bin/sh\nprintf "xcodebuild\\n" >> "$MOCK_LOG"\nprintf "<%s>\\n" "$@" >> "$MOCK_LOG"\n',
    }.items():
        executable = bin_dir / name
        executable.write_text(body)
        executable.chmod(0o755)
    log = temporary / "calls"
    environment = os.environ.copy()
    for key in ("TEAM_ID", "EXPORT_METHOD", "MOCK_CERTS"):
        environment.pop(key, None)
    environment.update(PATH=f"{bin_dir}:{environment['PATH']}", MOCK_LOG=str(log))

    def release(folder, *arguments, **settings):
        values = environment.copy()
        values.update(OUT_DIR=str(temporary / folder), **settings)
        return subprocess.run([str(ROOT / "Scripts/release.sh"), *arguments], cwd=ROOT,
                              env=values, capture_output=True, text=True)

    unsigned = release("unsigned", "--dry-run")
    assert unsigned.returncode == 0 and "CODE_SIGNING_ALLOWED=NO" in unsigned.stdout
    assert not (temporary / "unsigned").exists() and not log.exists()

    store_dry = release("store-dry", "--dry-run", TEAM_ID="ABCDE12345", EXPORT_METHOD="app-store")
    assert store_dry.returncode == 0 and "method=app-store-connect" in store_dry.stdout
    assert "DEVELOPMENT_TEAM=ABCDE12345" in store_dry.stdout
    assert "-allowProvisioningUpdates" in store_dry.stdout
    assert not (temporary / "store-dry").exists() and not log.exists()

    missing = release("missing", TEAM_ID="ABCDE12345", MOCK_CERTS="none")
    assert missing.returncode != 0 and "Missing Developer ID Application" in missing.stderr
    assert not (temporary / "missing").exists() and not log.exists()

    developer = release("developer", TEAM_ID="ABCDE12345")
    assert developer.returncode == 0, developer.stderr
    assert "<CODE_SIGN_IDENTITY=Developer ID Application:>" not in log.read_text()
    assert "<DEVELOPMENT_TEAM=ABCDE12345>" in log.read_text()

    log.unlink()
    store = release("store", TEAM_ID="ABCDE12345", EXPORT_METHOD="app-store-connect", MOCK_CERTS="none")
    assert store.returncode == 0, store.stderr
    assert "<-allowProvisioningUpdates>" in log.read_text()
    assert "<CODE_SIGN_IDENTITY=Developer ID Application:>" not in log.read_text()
    assert "<string>app-store-connect</string>" in (temporary / "store/ExportOptions.plist").read_text()

print("release script checks passed")
