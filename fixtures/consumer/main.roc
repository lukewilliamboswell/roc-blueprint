# Independent consumer of the pure core and Nix package, never the CLI.
app [main!] {
	pf: platform "../../.basic-cli/main.roc",
	ir: "../../blueprint-ir-package/main.roc",
	nix: "../../blueprint-nix-package/main.roc",
}

import pf.Stdout
import ir.Ir
import ir.Project
import nix.Backend
import nix.NixBackend
import "../../blueprint-nix-package/tests/sample.ir.scm" as wire : Str
import "../../blueprint-nix-package/tests/sample.golden.nix" as golden : Str
import "inputs.lock" as lock_contents : Str

layout : Backend.Layout
layout = {
	project_root: "/consumer/project",
	workspace: "/consumer/work",
	generated_root: "/consumer/work/generated",
	lock_path: "/consumer/pins/inputs.lock",
}

# Lock parsing and identity validation remain outside this trusted staging seam.
locked : Backend.LockedInputs
locked = { contents: lock_contents }

project : Str -> Try(Ir, Str)
project = |text| {
	decoded = Ir.parse(text).map_err(|_| "invalid fixture IR")?
	Project.validate(decoded)
}

files : {} -> Try(List(Backend.File), Str)
files = |_| NixBackend.render_files(
	project(wire)?,
	"x86_64-linux",
	layout,
	locked,
)

# The same validated IR renders byte-identical files at caller-owned locations.
expect files({}) == Ok([
	{ path: "/consumer/work/generated/flake.nix", contents: golden },
	{ path: "/consumer/work/generated/flake.lock", contents: locked.contents },
])

# Caller-selected requests render only their environment and its shell aliases.
expect match project(wire) {
	Ok(ir) => match NixBackend.render_environment(ir, "base") {
		Ok(text) => text.contains("\"blueprint-env-base\"")
			and !text.contains("\"blueprint-env-dev\"")
				and !text.contains("llvmPackages")
		Err(_) => False
	}
	Err(_) => False
}

# Staging cannot quietly select an undeclared target.
expect match project(wire) {
	Ok(ir) => NixBackend.render_files(
		ir,
		"unsupported",
		layout,
		locked,
	).is_err()
	Err(_) => False
}

# Caller-owned paths still reject lexical parent traversal before file effects.
expect match project(wire) {
	Ok(ir) => NixBackend.render_files(
		ir,
		"x86_64-linux",
		{ ..layout, generated_root: "/consumer/../escape" },
		locked,
	).is_err()
	Err(_) => False
}

# Package sources and ordinary inputs both refuse unrebased local URLs.
expect [
	wire.replace_each(
		"github:NixOS/nixpkgs/nixos-unstable",
		"path:./packages",
	),
	wire.replace_each("github:roc-lang/roc-overlay", "git+file:./overlay"),
].all(
	|text| match project(text) {
		Ok(ir) => NixBackend.render_files(
			ir,
			"x86_64-linux",
			layout,
			locked,
		).is_err()
		Err(_) => False
	},
)

# A declared but unsupported target is still rejected by the shared renderer.
expect match project(wire.replace_each("aarch64-darwin", "riscv64-linux")) {
	Ok(ir) => NixBackend.render_files(
		ir,
		"x86_64-linux",
		layout,
		locked,
	).is_err()
	Err(_) => False
}

# Staging is not a bypass for required feature support checks.
expect match project(
	wire.replace_each(
		"(systems",
		"(requires (\"future-build\")) (systems",
	),
) {
	Ok(ir) => NixBackend.render_files(
		ir,
		"x86_64-linux",
		layout,
		locked,
	).is_err()
	Err(_) => False
}

# Task argument boundaries survive the pure command contract exactly.
expect (NixBackend.backend.run_in_shell)(
	layout.generated_root,
	NixBackend.environment_shell("base"),
	["printf", "%s", "two words", "", "--literal"],
) == [
	"nix",
	"develop",
	"path:/consumer/work/generated#blueprint-env-base",
	"-c",
	"printf",
	"%s",
	"two words",
	"",
	"--literal",
]

main! = |_args| {
	generated = files({}).map_err(|_| Exit(1))?
	for file in generated {
		Stdout.line!("# ${file.path}")?
		Stdout.write!(file.contents)?
	}
	Ok({})
}
