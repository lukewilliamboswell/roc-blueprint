#!/usr/bin/env python3
"""Offline third-party SBOM conformance; no Blueprint validator is imported.

Install the adjacent hash-locked requirements once. Validation then uses only
vendored publisher schemas and local files. Exit 0: all expected outcomes;
1: invalid document/unexpected fixture outcome; 2: unsupported/configuration.
"""
from __future__ import annotations

import argparse
import contextlib
import glob
import hashlib
import importlib.metadata
import io
import json
from pathlib import Path
import shlex
import sys
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[2]
SCHEMAS = ROOT / "tests/sbom/schema"
SCHEMA_HASHES = {
    "spdx-3.0.1.schema.json": "582c64e809d5b3ef9bd0c4de13a32391b47b0284a3e8d199569fb96f649234b1",
    "spdx-2.3.schema.json": "4126dc29f15e92feec92e9622f4939131ad58b125d6f578aa93e980a6e6f3212",
    "cyclonedx-1.7/bom-1.7.schema.json": "73308edec3ab2d38bfffd993e96a042b594314143b6971a6e9ed98bbb6bd76ce",
    "cyclonedx-1.7/spdx.schema.json": "4b345e2329f209f34e960ae2a8e7cb46a166907e6a45e94978565925dc47b359",
    "cyclonedx-1.7/jsf-0.82.schema.json": "8bae002c25e723db7ee1f26afde680ae1a2b1a8f6b4b4b0fd65dc3becb090aae",
    "cyclonedx-1.7/cryptography-defs.schema.json": "027b059a729a06d591bac79a584ef04f83fc32d91a826fdba6ad3c98a10e5b44",
}
MAX_BYTES = 16 * 1024 * 1024


class ToolError(Exception):
    """Unsupported input or unavailable validation is never a pass."""


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def reject_constant(value):
    raise ValueError(f"invalid JSON number: {value}")


def check_depth(raw):
    # Bound nesting before JSON decoding, including ignored/unknown members.
    # Brackets inside strings are data; escaped quotes do not end a string.
    depth, quoted, escaped = 0, False, False
    for byte in raw:
        if quoted:
            if escaped:
                escaped = False
            elif byte == 92:
                escaped = True
            elif byte == 34:
                quoted = False
        elif byte == 34:
            quoted = True
        elif byte in (91, 123):
            depth += 1
            if depth > 64:
                raise ValueError("JSON nesting exceeds 64 levels")
        elif byte in (93, 125):
            depth -= 1


def check_unicode(value):
    # Python accepts escaped lone surrogates; the product's strict Unicode
    # reader refuses them. Check keys as well as string values before SDK use.
    if isinstance(value, str):
        value.encode("utf-8")
    elif isinstance(value, dict):
        for key, child in value.items():
            check_unicode(key)
            check_unicode(child)
    elif isinstance(value, list):
        for child in value:
            check_unicode(child)


def read_json(path: Path):
    if not path.is_file():
        raise ToolError("SBOM input must be a regular file")
    with path.open("rb") as source:
        raw = source.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        raise ValueError(f"input exceeds {MAX_BYTES} UTF-8 bytes")
    check_depth(raw)
    document = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object,
                          parse_constant=reject_constant)
    check_unicode(document)
    return document


def schema(name):
    path = SCHEMAS / name
    raw = path.read_bytes()
    if hashlib.sha256(raw).hexdigest() != SCHEMA_HASHES[name]:
        raise ToolError(f"publisher schema hash differs: {name}")
    return json.loads(raw)


def retrieve_schema(uri):
    # Never fall back to network resolution or arbitrary local files.
    name = Path(urlparse(uri).path).name
    key = "cyclonedx-1.7/" + name
    if key not in SCHEMA_HASHES:
        raise ToolError(f"unapproved external schema reference: {uri}")
    return schema(key)


def schema_errors(document, name):
    from jsonschema_rs import validator_for
    validator = validator_for(schema(name), retriever=retrieve_schema, validate_formats=True)
    return [{"message": error.message, "path": list(error.instance_path),
             "schema_path": list(error.schema_path)} for error in validator.iter_errors(document)]


def validate_file(path: Path):
    record = {"file": str(path), "status": "invalid", "errors": []}
    try:
        document = read_json(path)
        if not isinstance(document, dict):
            raise ValueError("an SBOM must be a JSON object")
        if document.get("bomFormat") == "CycloneDX":
            if document.get("specVersion") != "1.7":
                raise ToolError(f"unsupported CycloneDX version: {document.get('specVersion')}")
            record.update(format="cyclonedx-1.7", validation="publisher-schema")
            record["errors"] = schema_errors(document, "cyclonedx-1.7/bom-1.7.schema.json")
        elif document.get("spdxVersion") in ("SPDX-2.2", "SPDX-2.3"):
            from spdx_tools.spdx.validation.document_validator import validate_full_spdx_document
            version = document["spdxVersion"]
            record.update(format=version.lower(), validation="spdx-tools-semantic")
            if version == "SPDX-2.3":
                record["errors"] = schema_errors(document, "spdx-2.3.schema.json")
            # The SDK chooses the parser by extension; these are JSON inputs.
            # Parse the already checked object so a supplier's filename does
            # not select another serialization or bypass duplicate-key checks.
            from spdx_tools.spdx.parser.error import SPDXParsingError
            from spdx_tools.spdx.parser.jsonlikedict.json_like_dict_parser import JsonLikeDictParser
            messages = io.StringIO()
            try:
                with contextlib.redirect_stdout(messages), contextlib.redirect_stderr(messages):
                    parsed = JsonLikeDictParser().parse(document)
                    errors = validate_full_spdx_document(parsed)
            except SPDXParsingError as error:
                record["errors"].extend({"message": str(message)} for message in error.get_messages())
                return record
            record["errors"].extend({"message": error.validation_message,
                                     "element": error.context.spdx_id,
                                     "parent": error.context.parent_id}
                                    for error in errors)
        elif "@graph" in document:
            record.update(format="spdx-3.0.1", validation="publisher-schema")
            record["errors"] = schema_errors(document, "spdx-3.0.1.schema.json")
        else:
            raise ToolError("unsupported SBOM format/version; expected SPDX 2.2/2.3/3.0.1 or CycloneDX 1.7")
        record["status"] = "invalid" if record["errors"] else "valid"
    except ToolError as error:
        record.update(status="tool-error", errors=[{"message": str(error)}])
    except OSError as error:
        record.update(status="tool-error", errors=[{"message": str(error)}])
    except (ValueError, RecursionError, UnicodeError) as error:
        record["errors"] = [{"message": str(error)}]
    except Exception as error:
        # A validator exception cannot become a successful schema-only result.
        record.update(status="tool-error", errors=[{"message": f"{type(error).__name__}: {error}"}])
    return record


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("files", nargs="*", type=Path)
    parser.add_argument("--patterns", help="quoted shell-style path patterns, expanded without executing a shell")
    parser.add_argument("--fixture-cases", type=Path, help="run expected independent outcomes from a case manifest")
    parser.add_argument("--output", type=Path, help="write deterministic JSON instead of stdout")
    args = parser.parse_args(argv)
    paths = list(args.files)
    if args.patterns:
        for pattern in shlex.split(args.patterns):
            matches = sorted(glob.glob(pattern))
            if not matches:
                parser.error(f"no files match {pattern!r}")
            paths.extend(map(Path, matches))
    strict_paths = {path.resolve() for path in paths}
    try:
        versions = {name: importlib.metadata.version(name) for name in ("spdx-tools", "jsonschema-rs")}
    except importlib.metadata.PackageNotFoundError as error:
        parser.error(f"install scripts/sbom-conformance/requirements.txt first: {error}")
    expected = {}
    if args.fixture_cases:
        try:
            cases = read_json(args.fixture_cases)
        except (OSError, ValueError, ToolError) as error:
            parser.error(f"cannot read fixture manifest: {error}")
        for case in cases:
            path = args.fixture_cases.parent / case["file"]
            paths.append(path)
            expected[str(path)] = case
    if not paths:
        parser.error("supply SBOM files, --patterns or --fixture-cases")
    records = [validate_file(path) for path in sorted(set(paths))]
    for record in records:
        record["artifact_required_valid"] = Path(record["file"]).resolve() in strict_paths
        if record["file"] in expected:
            case = expected[record["file"]]
            record["fixture_required_valid"] = case["valid"]
            record["expected_valid"] = case.get("independent_valid", case["valid"])
            if "independent_limit" in case:
                record["independent_limit"] = case["independent_limit"]
            record["expectation_met"] = (record["status"] == "valid") == record["expected_valid"]
    report = {"tools": versions, "results": records}
    encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded)
    else:
        print(encoded, end="")
    if any(record["status"] == "tool-error" for record in records):
        return 2
    if any(record["artifact_required_valid"] and record["status"] != "valid" for record in records):
        return 1
    if any(not record.get("expectation_met", record["status"] == "valid") for record in records):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
