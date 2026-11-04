"""Exercise independent-validator behavior and its offline failure boundary."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("sbom_conformance", Path(__file__).with_name("validate.py"))
conformance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(conformance)


class IndependentConformance(unittest.TestCase):
    def temporary_document(self, raw):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = Path(directory.name) / "document.json"
        path.write_text(raw)
        return path

    def test_shared_semantic_cases(self):
        cases = conformance.ROOT / "tests/sbom/conformance/cases.json"
        for case in json.loads(cases.read_text()):
            with self.subTest(case=case["file"]):
                result = conformance.validate_file(cases.parent / case["file"])
                self.assertNotEqual(result["status"], "tool-error", result)
                self.assertEqual(result["status"] == "valid", case.get("independent_valid", case["valid"]), result)

    def test_cyclonedx_and_spdx3_publisher_schemas(self):
        for filename in ["native-linux.cdx.json", "native-linux.spdx.json"]:
            with self.subTest(filename=filename):
                path = conformance.ROOT / "tests/sbom/fixtures" / filename
                document = json.loads(path.read_text())
                self.assertEqual(conformance.validate_file(path)["status"], "valid")
                if filename.endswith(".cdx.json"):
                    document["metadata"]["component"]["type"] = "not-a-component-kind"
                else:
                    document["@graph"][0]["type"] = "not-an-spdx-class"
                invalid = self.temporary_document(json.dumps(document))
                self.assertEqual(conformance.validate_file(invalid)["status"], "invalid")

    def test_duplicate_keys_and_non_json_constants_fail_before_sdk(self):
        for text in ['{"spdxVersion":"SPDX-2.3","spdxVersion":"SPDX-2.3"}', '{"number":NaN}']:
            with self.subTest(text=text):
                result = conformance.validate_file(self.temporary_document(text))
                self.assertEqual(result["status"], "invalid")
                self.assertTrue(result["errors"])

    def test_depth_and_byte_limits_apply_before_validator_loading(self):
        boundary = self.temporary_document("[" * 64 + "null" + "]" * 64)
        self.assertIsInstance(conformance.read_json(boundary), list)
        too_deep = self.temporary_document("[" * 65 + "null" + "]" * 65)
        too_large = self.temporary_document(" " * (conformance.MAX_BYTES + 1))
        for path in [too_deep, too_large]:
            with self.subTest(path=path):
                with self.assertRaises(ValueError):
                    conformance.read_json(path)
        quoted = self.temporary_document(json.dumps({"text": "\"[" * 128}))
        self.assertIn("text", conformance.read_json(quoted))

    def test_input_is_utf8_instead_of_stdlib_encoding_autodetection(self):
        path = self.temporary_document("{}")
        path.write_bytes('{"spdxVersion":"SPDX-2.3"}'.encode("utf-16"))
        self.assertEqual(conformance.validate_file(path)["status"], "invalid")

    def test_lone_surrogates_in_values_and_keys_fail_before_sdk(self):
        for text in ['{"name":"\\ud800"}', '{"\\udc00":"value"}']:
            with self.subTest(text=text):
                result = conformance.validate_file(self.temporary_document(text))
                self.assertEqual(result["status"], "invalid")
                self.assertTrue(result["errors"])

    def test_nonregular_input_is_not_opened(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        result = conformance.validate_file(Path(directory.name))
        self.assertEqual(result["status"], "tool-error")
        self.assertIn("regular file", result["errors"][0]["message"])

    def test_bad_spdx_shape_is_invalid_not_tool_failure(self):
        path = self.temporary_document('{"spdxVersion":"SPDX-2.3"}')
        self.assertEqual(conformance.validate_file(path)["status"], "invalid")

    def test_unsupported_versions_are_never_silently_passed(self):
        path = self.temporary_document('{"bomFormat":"CycloneDX","specVersion":"9.0"}')
        self.assertEqual(conformance.validate_file(path)["status"], "tool-error")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(conformance.main([str(path)]), 2)

    def test_fixture_expectations_cannot_exempt_selected_invalid_artifacts(self):
        cases = conformance.ROOT / "tests/sbom/conformance/cases.json"
        invalid = cases.parent / "missing-file-sha1.spdx.json"
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(conformance.main(["--fixture-cases", str(cases)]), 0)
        for selected in [str(invalid), os.path.relpath(invalid)]:
            with self.subTest(selected=selected), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(conformance.main([selected, "--fixture-cases", str(cases)]), 1)

    def test_missing_negative_fixture_is_a_configuration_failure(self):
        manifest = self.temporary_document('[{"file":"missing-negative.spdx.json","valid":false}]')
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(conformance.main(["--fixture-cases", str(manifest)]), 2)

    def test_remote_schema_reference_has_no_network_fallback(self):
        with self.assertRaises(conformance.ToolError):
            conformance.retrieve_schema("https://untrusted.example/schema.json")

    def test_missing_input_is_not_an_empty_success(self):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as error:
                conformance.main(["--patterns", "/no-such-sbom-conformance-input/*.json"])
        self.assertEqual(error.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
