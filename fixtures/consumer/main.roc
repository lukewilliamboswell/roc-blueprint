## Independent consumer: no import of, or subprocess call to, Blueprint CLI.
app [main!] {
	pf: platform "../../.basic-cli/main.roc",
	ir: "../../blueprint-ir-package/main.roc",
	nix: "../../blueprint-nix-package/main.roc",
}

import pf.Stdout
import ir.Ir
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

# At B0 the caller supplies trusted, already-resolved lock bytes. Lock parsing
# and source identity validation are not yet implemented by this staging seam.
locked : Backend.LockedInputs
locked = { contents: lock_contents }

files : {} -> Try(List(Backend.File), Str)
files = |_| {
	project = Ir.parse(wire).map_err(|_| "invalid fixture IR")?
	NixBackend.render_files(project, "x86_64-linux", layout, locked)
}

expect files({}) == Ok([
	{ path: "/consumer/work/generated/flake.nix", contents: golden },
	{ path: "/consumer/work/generated/flake.lock", contents: locked.contents },
])

expect match Ir.parse(wire) {
	Ok(project) => NixBackend.render_files(project, "unsupported", layout, locked).is_err()
	Err(_) => False
}

expect match Ir.parse(wire) {
	Ok(project) => NixBackend.render_files(project, "x86_64-linux", { ..layout, generated_root: "/consumer/../escape" }, locked).is_err()
	Err(_) => False
}

expect match Ir.parse(wire.replace_each("github:NixOS/nixpkgs/nixos-unstable", "path:./packages")) {
	Ok(project) => NixBackend.render_files(project, "x86_64-linux", layout, locked).is_err()
	Err(_) => False
}

expect (NixBackend.backend.run_in_shell)(layout.generated_root, "ci", ["printf", "%s", "two words", "", "--literal"]) == ["nix", "develop", "path:/consumer/work/generated#ci", "-c", "printf", "%s", "two words", "", "--literal"]

main! = |_args| {
	generated = files({}).map_err(|_| Exit(1))?
	for file in generated {
		Stdout.line!("# ${file.path}")?
		Stdout.write!(file.contents)?
	}
	Ok({})
}
