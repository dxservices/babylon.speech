#!/usr/bin/env python3

from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
IGNORED_PARTS = {".build", ".git", ".swiftpm"}
CJK = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]")
TEXT_SUFFIXES = {".md", ".py", ".swift", ".yml", ".yaml"}
FORBIDDEN_NEUTRAL_TERMS = {
    "OpenAI",
    "Google",
    "WebSocket",
    "gRPC",
    "base64",
    "AVFAudio",
    "AVAudioSession",
    "AVAudioEngine",
    "Keychain",
}


def repository_text_files():
    for path in ROOT.rglob("*"):
        if not path.is_file() or any(part in IGNORED_PARTS for part in path.parts):
            continue
        if path.suffix in TEXT_SUFFIXES or path.name in {"Package.swift", "AGENTS.md"}:
            yield path


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


for file_path in repository_text_files():
    text = file_path.read_text(encoding="utf-8")
    if CJK.search(text):
        fail(f"Non-English CJK text found in {file_path.relative_to(ROOT)}")

neutral_root = ROOT / "Sources" / "BabylonSpeech"
for file_path in neutral_root.rglob("*.swift"):
    text = file_path.read_text(encoding="utf-8")
    for term in FORBIDDEN_NEUTRAL_TERMS:
        if term in text:
            fail(f"Forbidden neutral-target term {term!r} found in {file_path.relative_to(ROOT)}")

if (ROOT / ".git").exists():
    result = subprocess.run(
        ["git", "log", "-1", "--pretty=%B"],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode == 0 and CJK.search(result.stdout):
        fail("Non-English CJK text found in the latest commit message")

print("Repository language and neutral-target boundary checks passed.")

