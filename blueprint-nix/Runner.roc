# Immutable execution engine/toolchain pins, deliberately independent of CLI
# patch releases. Changing any of these is a runner-protocol upgrade.
import core.Spec
import "Runner.nix" as expression : Str

Runner :: [].{
	compiler : Spec.SourceFile
	compiler = {
		name: "blueprint-runner-compiler-v1",
		url: "https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-18-1df370f/roc_nightly-linux_x86_64-2026-10-18-1df370f.tar.gz",
		sha256: "0821ea1a9772f921f0b4eb1cd400238abb59b0247db2810f0ea865426f782e9d",
	}

	# Signed roc-automation source commit, fetched and checked as original bytes.
	source : { url : Str, sha256 : Str }
	source = { url: "https://raw.githubusercontent.com/lukewilliamboswell/roc-automation/1f4595b31b1fce3816dccb5501bc2f6dfcd893db/tools/roc-build-runner/main.roc", sha256: "7414654ddebb44b3c26216a1b154b6ef3986e261500cae2d33fa0788da8918a6" }

	compiler_tag : Str
	compiler_tag = "nightly-2026-10-18-1df370f"

	nix : Str
	nix = expression
}
