import cli.Env
import cli.Path
import core.Sbom
import core.Spdx3
import Process
import Script

## The native `scripts/sbom.roc` tool against read-only copies of
## `tests/sbom/fixtures/input`: `inspect` reproduces the committed inventory,
## `bind` writes SPDX 3.0.1, SPDX 2.3 and CycloneDX 1.7 that read back to one
## package graph, both default sidecars beside the artifact when no output is
## named, and every refusal the tool promises holds. Inputs are never changed.
##
## `chmod`, `ln -s` and `mkfifo` set up the cases basic-cli cannot create; the
## checks themselves are Roc.
SbomBindingTest := [].{
	run! : Str, Str => Try({}, _)
	run! = |tool, fixtures| {
		work = Path.to_str(Env.create_temp_dir_with_prefix!("blueprint-sbom-binding-")?)?
		result = cases!(tool, fixtures, work)
		_ = Path.delete_all!(Path.utf8(work))
		result
	}
}

inputs = ["Spec", "Lock", "composition.json", "inventory.json", "subject.json", "context.json", "sample-artifact"]

cases! = |tool, fixtures, work| {
	for name in inputs {
		Path.write_utf8!(Path.utf8("${work}/${name}"), Path.read_utf8!(Path.utf8("${fixtures}/${name}"))?)?
	}
	var $original = []
	for name in inputs {
		$original = $original.append((name, Path.read_utf8!(Path.utf8("${work}/${name}"))?))
	}
	original = $original
	_ = Process.succeed!(Process.command("chmod", ["0444"].concat(inputs), work))?
	call! = |args, success| {
		result = Process.traced!(Process.command(tool, args, work))?
		if (result.code == 0) != success {
			return Script.fail!("sbom ${Str.join_with(args, " ")} ${if (success) "failed" else "succeeded"}: ${result.stderr}")
		}
		for (name, text) in original {
			if Path.read_utf8!(Path.utf8("${work}/${name}")) != Ok(text) {
				return Script.fail!("sbom ${Str.join_with(args, " ")} changed its input ${name}")
			}
		}
		Ok({})
	}
	call!(["inspect", "Spec", "Lock", "composition.json", "x86_64-linux", "inspected.json"], True)?
	inspected : Try(Sbom.Inventory, _)
	inspected = Json.parse(Path.read_utf8!(Path.utf8("${work}/inspected.json"))?)
	committed : Try(Sbom.Inventory, _)
	committed = Json.parse(Path.read_utf8!(Path.utf8("${work}/inventory.json"))?)
	if inspected.is_err() or inspected != committed {
		return Script.fail!("inspect does not reproduce tests/sbom/fixtures/input/inventory.json")
	}

	base = ["bind", "inventory.json", "subject.json", "context.json", "sample-artifact"]
	call!(base.append("new.spdx.json"), True)?
	call!(base.concat(["new.spdx-2.3.json", "--spdx-2.3"]), True)?
	three = Path.read_utf8!(Path.utf8("${work}/new.spdx.json"))?
	two = Path.read_utf8!(Path.utf8("${work}/new.spdx-2.3.json"))?
	if Spdx3.validate(three).is_err() {
		return Script.fail!("bind wrote SPDX 3.0.1 the model rejects")
	}
	# Without an output, bind writes SPDX 3.0.1 and CycloneDX beside the artifact.
	call!(base, True)?
	beside = Path.read_utf8!(Path.utf8("${work}/sample-artifact.spdx.json"))?
	bom = Path.read_utf8!(Path.utf8("${work}/sample-artifact.cdx.json"))?
	if beside != three {
		return Script.fail!("the default SPDX sidecar differs from an explicit one")
	}
	match (Sbom.read(three), Sbom.read(two), Sbom.read_cyclonedx(bom)) {
		(Ok(from_three), Ok(from_two), Ok(from_bom)) =>
			if { ..from_three, version: "" } != { ..from_two, version: "" } or { ..from_three, version: "" } != { ..from_bom, version: "" } {
				return Script.fail!("the SPDX 3.0.1, SPDX 2.3 and CycloneDX sidecars state different package graphs")
			}
		_ => return Script.fail!("a bound sidecar does not read back")
	}
	call!(base, False)?
	call!(base.concat(["new.cdx.json", "--cyclonedx"]), True)?
	# The tool checks what it bound: profile, artifact bytes, inventory, and one
	# graph across formats; a tampered sidecar does not pass.
	call!(["check", "--artifacts", ".", "--inventory", "inventory.json", "sample-artifact.spdx.json", "sample-artifact.cdx.json", "new.spdx-2.3.json"], True)?
	Path.write_utf8!(Path.utf8("${work}/tampered.cdx.json"), bom.replace_each("\"scope\":\"excluded\"", "\"scope\":\"required\""))?
	if !bom.contains("\"scope\":\"excluded\"") {
		return Script.fail!("the bound CycloneDX sidecar has no build-only component to tamper with")
	}
	call!(["check", "tampered.cdx.json"], False)?
	call!(["check", "--artifacts", "nested", "sample-artifact.spdx.json"], False)?
	if Path.read_utf8!(Path.utf8("${work}/new.cdx.json"))? != bom {
		return Script.fail!("the default CycloneDX sidecar differs from an explicit one")
	}

	# An existing sidecar, or any input, is never replaced.
	call!(base.append("new.spdx.json"), False)?
	for name in ["sample-artifact", "inventory.json", "subject.json", "context.json"] {
		call!(base.append(name), False)?
	}
	Path.create_all!(Path.utf8("${work}/nested"))?
	call!(base.append("nested/../sample-artifact"), False)?

	# The subject is a regular file named in subject.json, not an alias of one.
	Path.hard_link!(Path.utf8("${work}/sample-artifact"), Path.utf8("${work}/artifact-hardlink"))?
	call!(["bind", "inventory.json", "subject.json", "context.json", "artifact-hardlink", "hardlink-result.json"], False)?
	_ = Process.succeed!(Process.command("ln", ["-s", "sample-artifact", "artifact-symlink"], work))?
	call!(["bind", "inventory.json", "subject.json", "context.json", "artifact-symlink", "symlink-result.json"], False)?
	Path.create_all!(Path.utf8("${work}/symlink-parent"))?
	_ = Process.succeed!(Process.command("ln", ["-s", "${work}/sample-artifact", "symlink-parent/sample-artifact"], work))?
	call!(["bind", "inventory.json", "subject.json", "context.json", "symlink-parent/sample-artifact", "symlink-parent-result.json"], False)?
	_ = Process.succeed!(Process.command("mkfifo", ["input-fifo"], work))?
	call!(["bind", "inventory.json", "subject.json", "input-fifo", "sample-artifact", "fifo-result.json"], False)?

	# Bounded inputs, and a subject or target that differs from the artifact.
	Path.write_utf8!(Path.utf8("${work}/oversized.json"), Str.join_with(List.repeat(" ", 1024 * 1024 + 1), ""))?
	call!(["inspect", "Spec", "Lock", "oversized.json", "x86_64-linux", "oversized-result.json"], False)?
	subject = Path.read_utf8!(Path.utf8("${work}/subject.json"))?
	written_sha = subject.split_on("\"sha256\":\"").get(1).map_ok(|rest| rest.split_on("\"").first() ?? "") ?? ""
	if !written_sha.is_empty() {
		Path.write_utf8!(Path.utf8("${work}/wrong-subject.json"), subject.replace_each(written_sha, Str.join_with(List.repeat("b", 64), "")))?
		call!(["bind", "inventory.json", "wrong-subject.json", "context.json", "sample-artifact", "wrong-subject-result.json"], False)?
	}
	Path.write_utf8!(Path.utf8("${work}/wrong-target.json"), Path.read_utf8!(Path.utf8("${work}/inventory.json"))?.replace_each("\"target\":\"x86_64-linux\"", "\"target\":\"aarch64-linux\""))?
	call!(["bind", "wrong-target.json", "subject.json", "context.json", "sample-artifact", "wrong-target-result.json"], False)?
	Script.pass!("SPDX binding: read-only inputs, exclusive sidecars, regular-file subjects, bounds, hash and target")
}
