#!/usr/bin/env python3

from dataclasses import dataclass
from pathlib import Path
import json
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
IGNORED_PARTS = {".build", ".git", ".swiftpm", "__pycache__"}
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
FAILURE_BODY_TERMS = re.compile(
    r"\b(?:body|message|payload|underlyingError)\b",
    re.IGNORECASE,
)
OPENAI_API_KEY_LOADER = re.compile(r"OPENAI_API_KEY")
RAW_ERROR_ALIAS = re.compile(r"(?:error|failure)$", re.IGNORECASE)
SAFE_ERROR_IDENTIFIER_SUFFIX = re.compile(
    r"(?:code|type|identifier|classification)$",
    re.IGNORECASE,
)
OPENAI_FORBIDDEN_PATTERNS = (
    (
        "audio framework",
        re.compile(r"\b(?:AVFoundation|AVFAudio|AVAudio[A-Za-z0-9_]*)\b"),
    ),
    (
        "credential ownership",
        re.compile(
            r"\b(?:Security|Keychain[A-Za-z0-9_]*|SecItem[A-Za-z0-9_]*|"
            r"kSec[A-Za-z0-9_]*|UserDefaults)\b"
            r"|\b(?:getenv|secure_getenv)\s*\("
            r"|\bProcessInfo\s*\.\s*processInfo\s*\.\s*environment\b"
            r"|\b\w*(?:credentialloader|credentialstore|"
            r"clientsecretloader|clientsecretstore|loadcredential|"
            r"storecredential|loadclientsecret|storeclientsecret)\w*\b",
            re.IGNORECASE,
        ),
    ),
    (
        "application policy",
        re.compile(
            r"\b\w*(?:retry|reconnect|backoff|recovery|fallback)\w*\b",
            re.IGNORECASE,
        ),
    ),
    (
        "UI and product state",
        re.compile(r"\b(?:SwiftUI|UIKit|AppKit|WatchKit|TVUIKit)\b"),
    ),
    (
        "persistence",
        re.compile(r"\b(?:CoreData|SwiftData|CloudKit)\b"),
    ),
    (
        "device ownership",
        re.compile(
            r"\b(?:CoreBluetooth|CoreLocation|CoreMotion|HealthKit|HomeKit|"
            r"LocalAuthentication|NearbyInteraction|UserNotifications)\b"
        ),
    ),
    (
        "logging",
        re.compile(
            r"\b(?:OSLog|Logger|NSLog)\b"
            r"|\bos_log\s*\("
            r"|\b(?:print|debugPrint|dump)\s*\("
        ),
    ),
    (
        "error retention",
        re.compile(
            r"\b(?:localizedDescription|underlyingError|rawPayload|rawJSON|"
            r"rawBody)\b"
            r"|\b\w*(?:fullError|retainedError|storedError|cachedError|"
            r"savedError)\w*\b"
            r"|\bString\s*\(\s*(?:describing|reflecting)\s*:\s*"
            r"(?:\w+\s*\.\s*)*\w*error\w*\b",
            re.IGNORECASE,
        ),
    ),
)
BABYLON_AUDIO_REFERENCE = re.compile(r"babylon[.-]audio", re.IGNORECASE)
BABYLON_AUDIO_URL = "https://github.com/dxservices/babylon.audio.git"
BABYLON_AUDIO_VERSION = "0.1.0"


@dataclass(frozen=True)
class SwiftToken:
    kind: str
    value: str
    in_interpolation: bool = False


class RepositoryCheckError(RuntimeError):
    pass


def repository_text_files(root: Path):
    for path in root.rglob("*"):
        if not path.is_file() or any(
            part in IGNORED_PARTS for part in path.parts
        ):
            continue
        if path.suffix in TEXT_SUFFIXES or path.name in EXPLICIT_TEXT_FILENAMES:
            yield path


def fail(message: str) -> None:
    raise RepositoryCheckError(message)


class SwiftLexer:
    def __init__(self, text: str):
        self.text = text

    def tokens(self) -> list[SwiftToken]:
        tokens, _ = self._scan_code(
            0,
            stop_at_closing_paren=False,
            in_interpolation=False,
        )
        return tokens

    def _scan_code(
        self,
        index: int,
        stop_at_closing_paren: bool,
        in_interpolation: bool,
    ) -> tuple[list[SwiftToken], int]:
        tokens: list[SwiftToken] = []
        paren_depth = 1 if stop_at_closing_paren else 0
        while index < len(self.text):
            if self.text.startswith("//", index):
                newline = self.text.find("\n", index + 2)
                index = len(self.text) if newline < 0 else newline + 1
                continue
            if self.text.startswith("/*", index):
                index = self._skip_block_comment(index)
                continue

            string_start = self._string_start(index)
            if string_start is not None:
                token, interpolation_tokens, index = self._scan_string(
                    index,
                    *string_start,
                )
                tokens.append(token)
                tokens.extend(interpolation_tokens)
                continue

            character = self.text[index]
            if character.isspace():
                index += 1
                continue
            if self._is_identifier_start(character):
                end = index + 1
                while end < len(self.text) and self._is_identifier_continue(
                    self.text[end]
                ):
                    end += 1
                tokens.append(
                    SwiftToken(
                        "identifier",
                        self.text[index:end],
                        in_interpolation,
                    )
                )
                index = end
                continue
            if character.isdigit():
                end = index + 1
                while end < len(self.text) and (
                    self.text[end].isalnum() or self.text[end] in "_."
                ):
                    end += 1
                tokens.append(
                    SwiftToken(
                        "number",
                        self.text[index:end],
                        in_interpolation,
                    )
                )
                index = end
                continue
            if character == "(" and stop_at_closing_paren:
                paren_depth += 1
            elif character == ")" and stop_at_closing_paren:
                paren_depth -= 1
                if paren_depth == 0:
                    return tokens, index + 1
            tokens.append(
                SwiftToken("symbol", character, in_interpolation)
            )
            index += 1
        if stop_at_closing_paren:
            fail("Malformed Swift source: unterminated string interpolation")
        return tokens, index

    def _skip_block_comment(self, index: int) -> int:
        depth = 1
        index += 2
        while index < len(self.text) and depth > 0:
            if self.text.startswith("/*", index):
                depth += 1
                index += 2
            elif self.text.startswith("*/", index):
                depth -= 1
                index += 2
            else:
                index += 1
        if depth != 0:
            fail("Malformed Swift source: unterminated block comment")
        return index

    def _string_start(self, index: int) -> tuple[int, int] | None:
        quote_index = index
        while quote_index < len(self.text) and self.text[quote_index] == "#":
            quote_index += 1
        if quote_index >= len(self.text) or self.text[quote_index] != '"':
            return None
        quote_count = 3 if self.text.startswith('"""', quote_index) else 1
        return quote_index - index, quote_count

    def _scan_string(
        self,
        index: int,
        hash_count: int,
        quote_count: int,
    ) -> tuple[SwiftToken, list[SwiftToken], int]:
        opening_length = hash_count + quote_count
        index += opening_length
        closing = '"' * quote_count + "#" * hash_count
        interpolation = "\\" + "#" * hash_count + "("
        escape = "\\" + "#" * hash_count
        literal: list[str] = []
        interpolation_tokens: list[SwiftToken] = []
        while index < len(self.text):
            if self.text.startswith(closing, index):
                return (
                    SwiftToken("string", "".join(literal)),
                    interpolation_tokens,
                    index + len(closing),
                )
            if self.text.startswith(interpolation, index):
                nested, index = self._scan_code(
                    index + len(interpolation),
                    stop_at_closing_paren=True,
                    in_interpolation=True,
                )
                interpolation_tokens.extend(nested)
                continue
            if self.text.startswith(escape, index):
                escaped_end = index + len(escape) + 1
                literal.append(self.text[index:min(escaped_end, len(self.text))])
                index = min(escaped_end, len(self.text))
                continue
            literal.append(self.text[index])
            index += 1
        fail("Malformed Swift source: unterminated string literal")

    @staticmethod
    def _is_identifier_start(character: str) -> bool:
        return (
            character == "_"
            or character.isalpha()
            or ord(character) >= 0x80
        )

    @classmethod
    def _is_identifier_continue(cls, character: str) -> bool:
        return cls._is_identifier_start(character) or character.isdigit()


def swift_code_projection(tokens: list[SwiftToken]) -> str:
    return " ".join(token.value for token in tokens if token.kind != "string")


def is_raw_error_alias(identifier: str) -> bool:
    # Lexical scanning cannot infer Swift expression types. Conventional aliases
    # ending in Error or Failure are treated as raw error values, while bounded
    # structured identifiers advertise their safe field suffix explicitly.
    return (
        RAW_ERROR_ALIAS.search(identifier) is not None
        and SAFE_ERROR_IDENTIFIER_SUFFIX.search(identifier) is None
    )


def check_openai_source_text(text: str, display_path: Path) -> None:
    tokens = SwiftLexer(text).tokens()
    for token in tokens:
        if token.kind in {"identifier", "string"} and (
            OPENAI_API_KEY_LOADER.search(token.value)
        ):
            fail(
                "Forbidden OpenAI target credential ownership term "
                f"'OPENAI_API_KEY' found in {display_path}"
            )
        if (
            token.kind == "identifier"
            and token.in_interpolation
            and is_raw_error_alias(token.value)
        ):
            fail(
                "Forbidden OpenAI target error retention term "
                f"{token.value!r} found in string interpolation in "
                f"{display_path}"
            )

    code = swift_code_projection(tokens)
    for category, pattern in OPENAI_FORBIDDEN_PATTERNS:
        match = pattern.search(code)
        if match:
            fail(
                f"Forbidden OpenAI target {category} term "
                f"{match.group(0)!r} found in {display_path}"
            )


def package_argument_lists(tokens: list[SwiftToken]) -> list[list[SwiftToken]]:
    arguments: list[list[SwiftToken]] = []
    index = 0
    while index + 2 < len(tokens):
        is_package_call = (
            tokens[index].value == "."
            and tokens[index + 1].kind == "identifier"
            and tokens[index + 1].value == "package"
            and tokens[index + 2].value == "("
        )
        if not is_package_call:
            index += 1
            continue

        depth = 1
        end = index + 3
        while end < len(tokens) and depth > 0:
            if tokens[end].value == "(":
                depth += 1
            elif tokens[end].value == ")":
                depth -= 1
            end += 1
        if depth != 0:
            fail("Malformed Swift package manifest: unbalanced .package call")
        arguments.append(tokens[index + 3:end - 1])
        index = end
    return arguments


def is_exact_babylon_audio_dependency(tokens: list[SwiftToken]) -> bool:
    values = [(token.kind, token.value) for token in tokens]
    if values and values[-1] == ("symbol", ","):
        values.pop()
    return values == [
        ("identifier", "url"),
        ("symbol", ":"),
        ("string", BABYLON_AUDIO_URL),
        ("symbol", ","),
        ("identifier", "exact"),
        ("symbol", ":"),
        ("string", BABYLON_AUDIO_VERSION),
    ]


def split_package_arguments(
    tokens: list[SwiftToken],
) -> list[list[SwiftToken]]:
    arguments: list[list[SwiftToken]] = []
    current: list[SwiftToken] = []
    stack: list[str] = []
    closing_for = {"(": ")", "[": "]", "{": "}"}
    for token in tokens:
        if token.value in closing_for:
            stack.append(closing_for[token.value])
            current.append(token)
            continue
        if token.value in closing_for.values():
            if not stack or stack.pop() != token.value:
                fail("Malformed Swift package manifest: unbalanced argument")
            current.append(token)
            continue
        if token.value == "," and not stack:
            arguments.append(current)
            current = []
            continue
        current.append(token)
    if stack:
        fail("Malformed Swift package manifest: unbalanced argument")
    if current:
        arguments.append(current)
    return arguments


def path_dependency_literal(tokens: list[SwiftToken]) -> str | None:
    path_arguments = []
    for argument in split_package_arguments(tokens):
        if (
            len(argument) >= 2
            and argument[0].kind == "identifier"
            and argument[0].value == "path"
            and argument[1].value == ":"
        ):
            path_arguments.append(argument[2:])
    if not path_arguments:
        return None
    if (
        len(path_arguments) == 1
        and len(path_arguments[0]) == 1
        and path_arguments[0][0].kind == "string"
    ):
        return path_arguments[0][0].value
    fail(
        "BabylonAudio dependency check rejects nonliteral local package paths"
    )


def dependency_mentions_babylon_audio(dependency: object) -> bool:
    if isinstance(dependency, str):
        return BABYLON_AUDIO_REFERENCE.search(dependency) is not None
    if isinstance(dependency, list):
        return any(
            dependency_mentions_babylon_audio(value) for value in dependency
        )
    if isinstance(dependency, dict):
        return any(
            dependency_mentions_babylon_audio(key)
            or dependency_mentions_babylon_audio(value)
            for key, value in dependency.items()
        )
    return False


def check_dump_package_json(text: str) -> None:
    try:
        payload = json.loads(text)
    except (json.JSONDecodeError, TypeError) as error:
        raise RepositoryCheckError(
            "Malformed swift package dump-package JSON"
        ) from error
    if not isinstance(payload, dict):
        fail("Malformed swift package dump-package JSON")
    dependencies = payload.get("dependencies")
    if not isinstance(dependencies, list):
        fail("Malformed swift package dump-package JSON")

    audio_dependencies = [
        dependency
        for dependency in dependencies
        if dependency_mentions_babylon_audio(dependency)
    ]
    if len(audio_dependencies) != 1:
        fail(
            "Exactly one effective BabylonAudio dependency must be present"
        )

    dependency = audio_dependencies[0]
    if not isinstance(dependency, dict) or set(dependency) != {
        "sourceControl"
    }:
        fail(
            "The effective BabylonAudio dependency must be source control"
        )
    source_controls = dependency["sourceControl"]
    if not isinstance(source_controls, list) or len(source_controls) != 1:
        fail(
            "The effective BabylonAudio dependency must be source control"
        )
    source_control = source_controls[0]
    if not isinstance(source_control, dict):
        fail("Malformed swift package dump-package JSON")

    location = source_control.get("location")
    remote = location.get("remote") if isinstance(location, dict) else None
    requirement = source_control.get("requirement")
    if (
        source_control.get("identity") != "babylon.audio"
        or not isinstance(location, dict)
        or set(location) != {"remote"}
        or not isinstance(remote, list)
        or len(remote) != 1
        or not isinstance(remote[0], dict)
        or remote[0] != {"urlString": BABYLON_AUDIO_URL}
        or requirement != {"exact": [BABYLON_AUDIO_VERSION]}
    ):
        fail(
            "The effective BabylonAudio dependency must use "
            f"{BABYLON_AUDIO_URL} exact {BABYLON_AUDIO_VERSION}"
        )


def check_manifest_text(text: str) -> None:
    dependency_bodies = package_argument_lists(SwiftLexer(text).tokens())
    for body in dependency_bodies:
        local_path = path_dependency_literal(body)
        if local_path is not None and BABYLON_AUDIO_REFERENCE.search(
            local_path
        ):
            fail(
                "BabylonAudio dependency must not use a local package path"
            )
    audio_dependencies = [
        body
        for body in dependency_bodies
        if any(
            token.kind == "string"
            and BABYLON_AUDIO_REFERENCE.search(token.value)
            for token in body
        )
    ]
    if len(audio_dependencies) != 1 or not is_exact_babylon_audio_dependency(
        audio_dependencies[0]
    ):
        fail(
            "BabylonAudio dependency must use "
            "https://github.com/dxservices/babylon.audio.git exact 0.1.0"
        )


def check_repository(root: Path = ROOT) -> None:
    for file_path in repository_text_files(root):
        text = file_path.read_text(encoding="utf-8")
        if CJK.search(text):
            fail(f"Non-English CJK text found in {file_path.relative_to(root)}")

    neutral_root = root / "Sources" / "BabylonSpeech"
    for file_path in neutral_root.rglob("*.swift"):
        text = file_path.read_text(encoding="utf-8")
        for term in FORBIDDEN_NEUTRAL_TERMS:
            if term in text:
                fail(
                    f"Forbidden neutral-target term {term!r} found in "
                    f"{file_path.relative_to(root)}"
                )

    event_contract = neutral_root / "SpeechEvents.swift"
    if event_contract.exists():
        match = EVENT_DATA_TERMS.search(
            event_contract.read_text(encoding="utf-8")
        )
        if match:
            fail(
                f"Audio data term {match.group(0)!r} found in the speech "
                "event contract"
            )

    failure_contract = neutral_root / "SpeechFailure.swift"
    if failure_contract.exists():
        match = FAILURE_BODY_TERMS.search(
            failure_contract.read_text(encoding="utf-8")
        )
        if match:
            fail(
                f"Error-body term {match.group(0)!r} found in the public "
                "failure contract"
            )

    openai_root = root / "Sources" / "BabylonSpeechOpenAI"
    for file_path in openai_root.rglob("*.swift"):
        check_openai_source_text(
            file_path.read_text(encoding="utf-8"),
            file_path.relative_to(root),
        )

    check_manifest_text((root / "Package.swift").read_text(encoding="utf-8"))

    dump_result = subprocess.run(
        ["swift", "package", "dump-package"],
        cwd=root,
        check=False,
        capture_output=True,
        text=True,
    )
    if dump_result.returncode != 0:
        fail("Unable to inspect the effective Swift package manifest")
    check_dump_package_json(dump_result.stdout)

    if not (root / ".git").exists():
        return

    shallow_result = subprocess.run(
        ["git", "rev-parse", "--is-shallow-repository"],
        cwd=root,
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
        cwd=root,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        fail("Unable to inspect reachable commit messages")
    if CJK.search(result.stdout):
        fail("Non-English CJK text found in reachable commit history")


def main() -> int:
    try:
        check_repository()
    except RepositoryCheckError as error:
        print(error, file=sys.stderr)
        return 1
    print("Repository language and product-boundary checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
