#!/usr/bin/env python3

from pathlib import Path
import json
import sys
import unittest

sys.dont_write_bytecode = True

from check_repository import (
    RepositoryCheckError,
    check_manifest_text,
    check_openai_source_text,
)
import check_repository as repository_check


ROOT = Path(__file__).resolve().parent.parent


class OpenAITargetBoundaryTests(unittest.TestCase):
    def assert_rejected(self, source: str, category: str) -> None:
        with self.assertRaisesRegex(RepositoryCheckError, category):
            check_openai_source_text(source, Path("Fixture.swift"))

    def test_rejects_audio_framework_ownership(self) -> None:
        fixtures = [
            "import AVFoundation",
            "import AVFAudio",
            "let engine = AVAudioEngine()",
        ]
        for source in fixtures:
            with self.subTest(source=source):
                self.assert_rejected(source, "audio framework")

    def test_rejects_credential_acquisition_and_storage(self) -> None:
        fixtures = [
            "import Security",
            "let keychain = KeychainStore()",
            "SecItemCopyMatching(query, nil)",
            "let kind = kSecClassGenericPassword",
            "let defaults = UserDefaults.standard",
            "let env = ProcessInfo.processInfo.environment",
            'let key = getenv("SERVICE_KEY")',
            'let keyName = "OPENAI_API_KEY"',
            "let loader = CredentialLoader()",
            "let store = OpenAICredentialStore()",
            "let loader = OpenAIClientSecretLoader()",
            "let loader = ClientSecretLoader()",
            "let secret = loadCredential()",
            "storeCredential(secret)",
        ]
        for source in fixtures:
            with self.subTest(source=source):
                self.assert_rejected(source, "credential ownership")

    def test_rejects_forbidden_code_inside_string_interpolation(self) -> None:
        fixtures = [
            'let value = "secret: \\(ProcessInfo.processInfo.environment)"',
            'let value = "secret: \\(KeychainStore())"',
            r'let value = #"secret: \#(KeychainStore())"#',
        ]
        for source in fixtures:
            with self.subTest(source=source):
                self.assert_rejected(source, "credential ownership")

    def test_rejects_error_values_stringified_by_interpolation(self) -> None:
        fixtures = [
            r'let value = "\(error)"',
            r'let value = "\(failure)"',
            r'let value = "\(providerError)"',
            r'let value = "\(caughtError)"',
            r'let value = #"\#(providerError)"#',
            r'let value = #"\#(failure)"#',
            r'let value = ##"\##(providerError)"##',
            r'''let value = """
            \(providerError)
            """''',
            r'''let value = """
            \(failure)
            """''',
            r'let value = "\("nested \(providerError)")"',
        ]
        for source in fixtures:
            with self.subTest(source=source):
                self.assert_rejected(source, "error retention")

    def test_allows_safe_interpolation_and_plain_error_prose(self) -> None:
        fixtures = [
            r'let value = "count: \(count)"',
            r'let value = "code: \(errorCode)"',
            r'let value = #"count: \#(count)"#',
            r'let value = #"code: \#(errorCode)"#',
            r'let value = #"type: \#(providerErrorType)"#',
            r'''let value = """
            count: \(count)
            """''',
            r'''let value = """
            code: \(errorCode)
            identifier: \(errorIdentifier)
            classification: \(errorClassification)
            """''',
            'let prose = "providerError belongs to the transport"',
        ]
        for source in fixtures:
            with self.subTest(source=source):
                check_openai_source_text(source, Path("SafeInterpolation.swift"))

    def test_comments_and_plain_strings_do_not_create_false_positives(self) -> None:
        source = r'''
        // OPENAI_API_KEY and SwiftUI are application concerns.
        /* outer KeychainStore and retryPolicy
           /* nested ProcessInfo.processInfo.environment and CoreData */
           recoveryPolicy
        */
        let prose = "KeychainStore retryPolicy SwiftUI CoreData debugPrint"
        '''

        check_openai_source_text(source, Path("AllowedProse.swift"))

    def test_openai_api_key_comment_passes_but_literal_and_code_reject(self) -> None:
        check_openai_source_text(
            "// OPENAI_API_KEY belongs to the application backend.",
            Path("Comment.swift"),
        )
        fixtures = [
            'let name = "OPENAI_API_KEY"',
            'let OPENAI_API_KEY = "forbidden"',
            'let αOPENAI_API_KEY = "forbidden"',
        ]
        for source in fixtures:
            with self.subTest(source=source):
                self.assert_rejected(source, "credential ownership")

    def test_rejects_application_recovery_policy(self) -> None:
        fixtures = [
            "let retryPolicy = RetryPolicy()",
            "reconnect()",
            "let backoff = Duration.seconds(1)",
            "performRecovery()",
            "useFallbackProvider()",
        ]
        for source in fixtures:
            with self.subTest(source=source):
                self.assert_rejected(source, "application policy")

    def test_rejects_unicode_prefixed_policy_identifier(self) -> None:
        self.assert_rejected(
            "let αretryPolicy = 1",
            "application policy",
        )

    def test_rejects_ui_persistence_and_device_ownership(self) -> None:
        fixtures = [
            ("import SwiftUI", "UI and product state"),
            ("import CoreData", "persistence"),
            ("import CoreBluetooth", "device ownership"),
        ]
        for source, category in fixtures:
            with self.subTest(source=source):
                self.assert_rejected(source, category)

    def test_rejects_logging(self) -> None:
        fixtures = [
            "import OSLog",
            "let logger = Logger()",
            'os_log("event")',
            'NSLog("event")',
            'print("event")',
            'debugPrint("event")',
            "dump(event)",
        ]
        for source in fixtures:
            with self.subTest(source=source):
                self.assert_rejected(source, "logging")

    def test_rejects_raw_or_full_error_retention(self) -> None:
        fixtures = [
            "let text = error.localizedDescription",
            "let underlyingError = error",
            "let rawPayload = bytes",
            "let rawJSON = json",
            "let rawBody = body",
            "let fullError = error",
            "private var retainedError: (any Error)?",
        ]
        for source in fixtures:
            with self.subTest(source=source):
                self.assert_rejected(source, "error retention")

    def test_rejects_full_error_stringification(self) -> None:
        fixtures = [
            "let text = String(describing: error)",
            "let text = String(reflecting: error)",
        ]
        for source in fixtures:
            with self.subTest(source=source):
                self.assert_rejected(source, "error retention")

    def test_allows_wire_and_sanitized_data_plane_terms(self) -> None:
        source = """
        import Foundation

        /// The app owns retry, reconnect, recovery, fallback, and logging.
        /// This target does not use Keychain, UserDefaults, or AVAudioEngine.
        let clientSecret = "short-lived"
        let boundaryDescription = "backoff and debugPrint are app policy"
        let pcmPayload = Data([0, 1])
        let decoded = try JSONDecoder().decode(Event.self, from: pcmPayload)
        let encoded = try JSONSerialization.data(withJSONObject: [:])
        let base64 = encoded.base64EncodedString()
        let onMessage: (Data) -> Void = { _ in }
        let translatedAudio = pcmPayload
        let rawType = "authentication_error"
        let rawCode = "invalid_api_key"
        """

        check_openai_source_text(source, Path("Allowed.swift"))

    def test_current_openai_target_passes(self) -> None:
        source_root = ROOT / "Sources" / "BabylonSpeechOpenAI"
        for path in sorted(source_root.glob("*.swift")):
            with self.subTest(path=path.name):
                check_openai_source_text(
                    path.read_text(encoding="utf-8"),
                    path.relative_to(ROOT),
                )

    def test_malformed_swift_lexemes_fail_closed(self) -> None:
        fixtures = [
            "/* outer /* nested */",
            'let value = "unterminated',
            'let value = #"unterminated',
            'let value = """unterminated',
            r'let value = "\(count"',
        ]
        for source in fixtures:
            with self.subTest(source=source):
                with self.assertRaisesRegex(
                    RepositoryCheckError,
                    "Malformed Swift source",
                ):
                    check_openai_source_text(source, Path("Malformed.swift"))


class ManifestBoundaryTests(unittest.TestCase):
    def test_requires_exact_remote_babylon_audio_release(self) -> None:
        allowed = """
        dependencies: [
            .package(
                url: "https://github.com/dxservices/babylon.audio.git",
                exact: "0.1.0"
            ),
        ]
        """
        check_manifest_text(allowed)

        rejected = [
            '.package(path: "../babylon.audio")',
            """
            .package(
                url: "https://github.com/dxservices/babylon.audio.git",
                from: "0.1.0"
            )
            """,
            """
            .package(
                url: "https://github.com/dxservices/babylon.audio.git",
                exact: "0.1.1"
            )
            """,
            """
            .package(
                url: "https://example.com/babylon.audio.git",
                exact: "0.1.0"
            )
            """,
        ]
        for manifest in rejected:
            with self.subTest(manifest=manifest):
                with self.assertRaisesRegex(
                    RepositoryCheckError,
                    "BabylonAudio dependency",
                ):
                    check_manifest_text(manifest)

    def test_current_manifest_passes(self) -> None:
        check_manifest_text(
            (ROOT / "Package.swift").read_text(encoding="utf-8")
        )

    def test_ignores_commented_and_string_fake_dependencies(self) -> None:
        manifest = r'''
        // .package(path: "../babylon-audio")
        /* outer .package(path: "../babylon.audio")
           /* nested .package(url: "fake", exact: "0.1.0") */
        */
        let documentation = ".package(path: \"../babylon-audio\")"
        dependencies: [
            .package(
                url: "https://github.com/dxservices/babylon.audio.git",
                exact: "0.1.0"
            ),
        ]
        '''

        check_manifest_text(manifest)

    def test_rejects_active_local_dependency_hidden_by_fake_exact(self) -> None:
        manifests = [
            r'''
            // .package(
            //     url: "https://github.com/dxservices/babylon.audio.git",
            //     exact: "0.1.0"
            // )
            dependencies: [.package(path: "../babylon-audio")]
            ''',
            r'''
            let fake = ".package(url: \"https://github.com/dxservices/"
                + "babylon.audio.git\", exact: \"0.1.0\")"
            dependencies: [.package(path: "../babylon.audio")]
            ''',
        ]
        for manifest in manifests:
            with self.subTest(manifest=manifest):
                with self.assertRaisesRegex(
                    RepositoryCheckError,
                    "BabylonAudio dependency",
                ):
                    check_manifest_text(manifest)

    def test_rejects_nested_call_or_nonliteral_dependency(self) -> None:
        manifests = [
            '''
            .package(
                url: repositoryURL(
                    "https://github.com/dxservices/babylon.audio.git"
                ),
                exact: "0.1.0"
            )
            ''',
            '.package(path: resolve("../babylon-audio"))',
        ]
        for manifest in manifests:
            with self.subTest(manifest=manifest):
                with self.assertRaisesRegex(
                    RepositoryCheckError,
                    "BabylonAudio dependency",
                ):
                    check_manifest_text(manifest)

    def test_rejects_conditional_local_bypass_with_concatenated_path(self) -> None:
        manifest = '''
        let useLocal = true
        let localPath = "../babylon" + ".audio"
        let audioDependency: Package.Dependency = useLocal
            ? .package(path: localPath)
            : .package(
                url: "https://github.com/dxservices/babylon.audio.git",
                exact: "0.1.0"
            )
        dependencies: [audioDependency]
        '''

        with self.assertRaisesRegex(
            RepositoryCheckError,
            "BabylonAudio dependency",
        ):
            check_manifest_text(manifest)

    def test_rejects_named_conditional_nonliteral_local_path(self) -> None:
        manifest = '''
        let useLocal = true
        let dependencyName = "BabylonAudio"
        let localPath = "../babylon" + ".audio"
        let audioDependency: Package.Dependency = useLocal
            ? .package(name: dependencyName, path: localPath)
            : .package(
                url: "https://github.com/dxservices/babylon.audio.git",
                exact: "0.1.0"
            )
        dependencies: [audioDependency]
        '''

        with self.assertRaisesRegex(
            RepositoryCheckError,
            "BabylonAudio dependency",
        ):
            check_manifest_text(manifest)

    def test_multiple_dependencies_allow_only_one_literal_exact_audio(self) -> None:
        allowed = '''
        dependencies: [
            .package(url: "https://example.com/other.git", exact: "1.0.0"),
            .package(
                url: "https://github.com/dxservices/babylon.audio.git",
                exact: "0.1.0"
            ),
        ]
        '''
        check_manifest_text(allowed)

        rejected = '''
        let localPath = "../babylon-audio"
        dependencies: [
            .package(
                url: "https://github.com/dxservices/babylon.audio.git",
                exact: "0.1.0"
            ),
            .package(path: localPath),
        ]
        '''
        with self.assertRaisesRegex(
            RepositoryCheckError,
            "BabylonAudio dependency",
        ):
            check_manifest_text(rejected)

    def test_rejects_url_and_path_indirection(self) -> None:
        manifests = [
            '''
            let audioURL = "https://github.com/dxservices/babylon.audio.git"
            dependencies: [.package(url: audioURL, exact: "0.1.0")]
            ''',
            '''
            let localPath = "../babylon-audio"
            dependencies: [.package(path: localPath)]
            ''',
        ]
        for manifest in manifests:
            with self.subTest(manifest=manifest):
                with self.assertRaisesRegex(
                    RepositoryCheckError,
                    "BabylonAudio dependency",
                ):
                    check_manifest_text(manifest)

    def test_unbalanced_package_call_fails_as_malformed(self) -> None:
        with self.assertRaisesRegex(
            RepositoryCheckError,
            "Malformed Swift package manifest",
        ):
            check_manifest_text(
                '.package(url: "https://github.com/dxservices/'
                'babylon.audio.git", exact: "0.1.0"'
            )


class DumpPackageBoundaryTests(unittest.TestCase):
    @staticmethod
    def exact_dependency() -> dict[str, object]:
        return {
            "sourceControl": [
                {
                    "identity": "babylon.audio",
                    "location": {
                        "remote": [
                            {
                                "urlString": (
                                    "https://github.com/dxservices/"
                                    "babylon.audio.git"
                                )
                            }
                        ]
                    },
                    "productFilter": None,
                    "requirement": {"exact": ["0.1.0"]},
                    "traits": [{"name": "default"}],
                }
            ]
        }

    def test_accepts_one_effective_exact_remote_dependency(self) -> None:
        payload = {
            "dependencies": [
                {
                    "sourceControl": [
                        {
                            "identity": "other",
                            "location": {
                                "remote": [
                                    {"urlString": "https://example.com/other.git"}
                                ]
                            },
                            "requirement": {"exact": ["1.0.0"]},
                        }
                    ]
                },
                self.exact_dependency(),
            ]
        }

        repository_check.check_dump_package_json(json.dumps(payload))

    def test_rejects_missing_duplicate_local_or_wrong_effective_dependency(
        self,
    ) -> None:
        exact = self.exact_dependency()
        wrong_version = self.exact_dependency()
        wrong_version["sourceControl"][0]["requirement"] = {
            "exact": ["0.1.1"]
        }
        wrong_url = self.exact_dependency()
        wrong_url["sourceControl"][0]["location"] = {
            "remote": [{"urlString": "https://example.com/babylon.audio.git"}]
        }
        missing_identity = self.exact_dependency()
        del missing_identity["sourceControl"][0]["identity"]
        wrong_identity = self.exact_dependency()
        wrong_identity["sourceControl"][0]["identity"] = "babylon-audio"
        mixed_location = self.exact_dependency()
        mixed_location["sourceControl"][0]["location"] = {
            "remote": [
                {
                    "urlString": (
                        "https://github.com/dxservices/babylon.audio.git"
                    )
                }
            ],
            "local": [{"path": "../babylon.audio"}],
        }
        malformed_remote = self.exact_dependency()
        malformed_remote["sourceControl"][0]["location"] = {
            "remote": [
                {
                    "urlString": (
                        "https://github.com/dxservices/babylon.audio.git"
                    ),
                    "path": "../babylon.audio",
                }
            ]
        }
        missing_location = self.exact_dependency()
        del missing_location["sourceControl"][0]["location"]
        multiple_remotes = self.exact_dependency()
        multiple_remotes["sourceControl"][0]["location"] = {
            "remote": [
                {
                    "urlString": (
                        "https://github.com/dxservices/babylon.audio.git"
                    )
                },
                {"urlString": "https://example.com/babylon.audio.git"},
            ]
        }
        multiple_source_controls = self.exact_dependency()
        multiple_source_controls["sourceControl"].append(
            self.exact_dependency()["sourceControl"][0]
        )
        fixtures = [
            {"dependencies": []},
            {"dependencies": [exact, self.exact_dependency()]},
            {
                "dependencies": [
                    {
                        "fileSystem": [
                            {
                                "identity": "babylon-audio",
                                "path": "../babylon-audio",
                            }
                        ]
                    }
                ]
            },
            {"dependencies": [wrong_version]},
            {"dependencies": [wrong_url]},
            {"dependencies": [missing_identity]},
            {"dependencies": [wrong_identity]},
            {"dependencies": [mixed_location]},
            {"dependencies": [malformed_remote]},
            {"dependencies": [missing_location]},
            {"dependencies": [multiple_remotes]},
            {"dependencies": [multiple_source_controls]},
        ]
        for payload in fixtures:
            with self.subTest(payload=payload):
                with self.assertRaisesRegex(
                    RepositoryCheckError,
                    "effective BabylonAudio dependency",
                ):
                    repository_check.check_dump_package_json(
                        json.dumps(payload)
                    )

    def test_rejects_malformed_dump_package_json(self) -> None:
        with self.assertRaisesRegex(
            RepositoryCheckError,
            "dump-package JSON",
        ):
            repository_check.check_dump_package_json("not-json")


if __name__ == "__main__":
    unittest.main()
