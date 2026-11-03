#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc2/Gj3zVDr3qrQa6aTh7Z1zgUfe9NeBE6R76T5ho3xrc8af.tar.zst",
	core: "../blueprint-core/main.roc",
	roc: "nightly-2026-10-13-b17d287",
}

import core.Spdx2
import core.JsonData
import "../tests/sbom/conformance/valid-native.spdx.json" as fixture_0 : Str
import "../tests/sbom/conformance/missing-file-sha1.spdx.json" as fixture_1 : Str
import "../tests/sbom/conformance/duplicate-file-sha1.spdx.json" as fixture_2 : Str
import "../tests/sbom/conformance/false-file-containment.spdx.json" as fixture_3 : Str
import "../tests/sbom/conformance/false-reverse-containment.spdx.json" as fixture_4 : Str
import "../tests/sbom/conformance/false-has-files.spdx.json" as fixture_5 : Str
import "../tests/sbom/conformance/false-verification-code.spdx.json" as fixture_6 : Str
import "../tests/sbom/conformance/false-file-licenses.spdx.json" as fixture_7 : Str
import "../tests/sbom/conformance/missing-verification-code.spdx.json" as fixture_8 : Str
import "../tests/sbom/conformance/malformed-verification-code.spdx.json" as fixture_9 : Str
import "../tests/sbom/conformance/invalid-id.spdx.json" as fixture_10 : Str
import "../tests/sbom/conformance/undefined-package-license.spdx.json" as fixture_11 : Str
import "../tests/sbom/conformance/undefined-file-license.spdx.json" as fixture_12 : Str
import "../tests/sbom/conformance/malformed-license-id.spdx.json" as fixture_13 : Str
import "../tests/sbom/conformance/duplicate-license-id.spdx.json" as fixture_14 : Str
import "../tests/sbom/conformance/valid-custom-license.spdx.json" as fixture_15 : Str

import "../tests/sbom/conformance/valid-external-license.spdx.json" as fixture_16 : Str

import "../tests/sbom/conformance/undefined-snippet-license.spdx.json" as fixture_17 : Str

# These same real File/package cases also run through independent validators.
main! = |_| Ok({})

# Valid native supplier document
expect Spdx2.validate(JsonData.decode(fixture_0) ?? crash "invalid fixture JSON").is_ok()

# File SHA1
expect Spdx2.validate(JsonData.decode(fixture_1) ?? crash "invalid fixture JSON").is_err()

# File SHA1 cardinality
expect Spdx2.validate(JsonData.decode(fixture_2) ?? crash "invalid fixture JSON").is_err()

# filesAnalyzed containment
expect Spdx2.validate(JsonData.decode(fixture_3) ?? crash "invalid fixture JSON").is_err()

# filesAnalyzed reverse containment
expect Spdx2.validate(JsonData.decode(fixture_4) ?? crash "invalid fixture JSON").is_err()

# filesAnalyzed hasFiles
expect Spdx2.validate(JsonData.decode(fixture_5) ?? crash "invalid fixture JSON").is_err()

# filesAnalyzed verification code
expect Spdx2.validate(JsonData.decode(fixture_6) ?? crash "invalid fixture JSON").is_err()

# filesAnalyzed licenseInfoFromFiles
expect Spdx2.validate(JsonData.decode(fixture_7) ?? crash "invalid fixture JSON").is_err()

# analyzed package verification code
expect Spdx2.validate(JsonData.decode(fixture_8) ?? crash "invalid fixture JSON").is_err()

# verification code syntax
expect Spdx2.validate(JsonData.decode(fixture_9) ?? crash "invalid fixture JSON").is_err()

# identifier alphabet
expect Spdx2.validate(JsonData.decode(fixture_10) ?? crash "invalid fixture JSON").is_err()

# LicenseRef declaration
expect Spdx2.validate(JsonData.decode(fixture_11) ?? crash "invalid fixture JSON").is_err()

# File LicenseRef declaration
expect Spdx2.validate(JsonData.decode(fixture_12) ?? crash "invalid fixture JSON").is_err()

# LicenseRef identifier alphabet
expect Spdx2.validate(JsonData.decode(fixture_13) ?? crash "invalid fixture JSON").is_err()

# LicenseRef uniqueness
expect Spdx2.validate(JsonData.decode(fixture_14) ?? crash "invalid fixture JSON").is_err()

# Valid native supplier document
expect Spdx2.validate(JsonData.decode(fixture_15) ?? crash "invalid fixture JSON").is_ok()

# Declared external LicenseRef
expect Spdx2.validate(JsonData.decode(fixture_16) ?? crash "invalid fixture JSON").is_ok()

# Snippet LicenseRef declaration
expect Spdx2.validate(JsonData.decode(fixture_17) ?? crash "invalid fixture JSON").is_err()
