#!/usr/bin/env python3

from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
IGNORED_PARTS = {".build", ".git", ".swiftpm"}
CJK = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]")
TEXT_SUFFIXES = {".json", ".md", ".py", ".swift", ".txt", ".yml", ".yaml"}
EXPLICIT_TEXT_FILENAMES = {
    ".gitattributes",
    ".gitignore",
    "AUTHORS",
    "COPYING",
    "LICENSE",
    "NOTICE",
}
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
    "JSONDecoder",
    "JSONEncoder",
    "Logger",
    "OSLog",
    "URLRequest",
    "URLSession",
}
EVENT_DATA_TERMS = re.compile(r"\b(?:AudioFrame|Data)\b")
FAILURE_BODY_TERMS = re.compile(r"\b(?:body|message|payload|underlyingError)\b", re.IGNORECASE)


def repository_text_files():
    for path in ROOT.rglob("*"):
        if not path.is_file() or any(part in IGNORED_PARTS for part in path.parts):
            continue
        if path.suffix in TEXT_SUFFIXES or path.name in EXPLICIT_TEXT_FILENAMES:
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

event_contract = neutral_root / "SpeechEvents.swift"
if event_contract.exists():
    match = EVENT_DATA_TERMS.search(event_contract.read_text(encoding="utf-8"))
    if match:
        fail(f"Audio data term {match.group(0)!r} found in the speech event contract")

failure_contract = neutral_root / "SpeechFailure.swift"
if failure_contract.exists():
    match = FAILURE_BODY_TERMS.search(failure_contract.read_text(encoding="utf-8"))
    if match:
        fail(f"Error-body term {match.group(0)!r} found in the public failure contract")

if (ROOT / ".git").exists():
    shallow_result = subprocess.run(
        ["git", "rev-parse", "--is-shallow-repository"],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if shallow_result.returncode != 0:
        fail("Unable to determine whether Git history is complete")
    if shallow_result.stdout.strip() == "true":
        fail("Full Git history is required for commit-message checks")

    result = subprocess.run(
        ["git", "log", "--all", "--format=%B"],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        fail("Unable to inspect reachable commit messages")
    if CJK.search(result.stdout):
        fail("Non-English CJK text found in reachable commit history")

print("Repository language and neutral-target boundary checks passed.")
