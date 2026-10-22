import cli.Env
import cli.Path
import Process
import Script

## The SBOM fixture set as a release ships it: `tests/sbom/fixtures/` with
## its case contract, archived so a consumer can run the released standalone
## tool over every case the test suite asserts without a checkout.
##
## `files` is the whole contents. `scripts/src/SbomTest.roc` requires it to
## be exactly the files that suite asserts, and `package!` requires it to be
## exactly what git tracks in the directory, so the asset can lag neither the
## suite nor the tree.
SbomFixtures := [].{

	## The directory the set lives in, below the repository root.
	directory = "tests/sbom/fixtures"

	## The case contract, at the top of the set.
	contract = "CONTRACT.md"

	## The archive's name without `.zip`, which is also its one top directory.
	archive_name : Str -> Str
	archive_name = |version| "roc-blueprint-sbom-fixtures-${version}"

	## The rendered cases, each held as `<case>.spdx.json`,
	## `<case>.spdx-2.3.json` and `<case>.cdx.json`.
	cases = ["native-arm64", "native-linux", "native-source-import", "source-bundle", "unknown-closure", "verified-empty", "verified-import"]

	## Every file the archive holds, below its top directory, in byte order.
	files : List(Str)
	files = Process.sorted(
		[contract]
			.concat(cases.fold([], |all, case| all.concat(["${case}.spdx.json", "${case}.spdx-2.3.json", "${case}.cdx.json"])))
			.concat(["Spec", "Lock", "composition.json", "inventory.json", "subject.json", "context.json", "sample-artifact"].map(|name| "input/${name}"))
			.concat(
				[
					"Spec",
					"Lock",
					"composition.json",
					"subject.json",
					"context.json",
					"consumer-artifact",
					"expected.json",
					"inventory-source.json",
					"inventory-x86_64-linux.json",
					"inventory-aarch64-linux.json",
					"tamper-document-digest.json",
					"tamper-subject-digest.json",
					"tamper-subject-version.json",
					"tamper-import-native.json",
					"tamper-component-native.json",
					"tamper-import-aarch64.json",
				].map(|name| "source-import/${name}"),
			)
			.concat(["README.md", "syft.cdx.json", "syft.spdx.json", "trivy.cdx.json", "trivy.spdx.json"].map(|name| "upstream/${name}")),
	)

	## The paths below `tests/sbom/fixtures` among what `git ls-files` printed.
	tracked : Str -> List(Str)
	tracked = |listed| Process.sorted(Process.lines(listed).keep_if(|path| path.starts_with("${directory}/")).map(|path| path.drop_prefix("${directory}/")))

	## What is wrong when git tracks other files in the directory than the
	## archive holds, or "" when the two agree.
	tracked_problem : List(Str) -> Str
	tracked_problem = |in_tree| {
		unlisted = in_tree.keep_if(|path| !files.contains(path))
		absent = files.keep_if(|path| !in_tree.contains(path))
		if unlisted.is_empty() and absent.is_empty() {
			""
		} else {
			"scripts/src/SbomFixtures.roc must list exactly the tracked files of ${directory} (not listed: ${Str.join_with(unlisted, " ")}; listed but untracked: ${Str.join_with(absent, " ")})"
		}
	}

	## Write `dist/roc-blueprint-sbom-fixtures-<version>.zip` from the
	## working tree, and require the archive to hold exactly `files`.
	package! : Str, Str => Try({}, _)
	package! = |root, version| {
		work = Path.to_str(Path.canonicalize!(Env.create_temp_dir_with_prefix!("blueprint-sbom-fixtures-")?)?)?
		result = staged!(root, version, work)
		_ = Path.delete_all!(Path.utf8(work))
		result
	}
}

parent : Str -> Str
parent = |file| Str.join_with(file.split_on("/").drop_last(1), "/")

staged! : Str, Str, Str => Try({}, _)
staged! = |root, version, work| {
	listed = Process.succeed!(Process.command("git", ["ls-files", "--", SbomFixtures.directory], root))?
	problem = SbomFixtures.tracked_problem(SbomFixtures.tracked(listed.stdout))
	Process.check!(problem.is_empty(), problem)?
	name = SbomFixtures.archive_name(version)
	top = "${work}/${name}"

	Script.info!("==>", "Staging the SBOM fixture set and its contract as ${name}")?
	for file in SbomFixtures.files {
		target = "${top}/${file}"
		Path.create_all!(Path.utf8(parent(target)))?
		Path.copy!(Path.utf8("${root}/${SbomFixtures.directory}/${file}"), Path.utf8(target))?
	}

	archive = "${root}/dist/${name}.zip"
	Path.create_all!(Path.utf8("${root}/dist"))?
	if Path.exists!(Path.utf8(archive))? {
		Path.delete!(Path.utf8(archive))?
	}
	_ = Process.succeed!(Process.command("zip", ["-q", "-r", "-X", archive, name], work))?

	held = Process.succeed!(Process.command("unzip", ["-Z1", archive], root))?
	members = Process.sorted(Process.lines(held.stdout).keep_if(|entry| !entry.ends_with("/")))
	wanted = SbomFixtures.files.map(|file| "${name}/${file}")
	Process.check!(members == wanted, "dist/${name}.zip holds:\n${Str.join_with(members, "\n")}\nexpected:\n${Str.join_with(wanted, "\n")}")?
	Script.pass!("wrote dist/${name}.zip with ${SbomFixtures.files.len().to_str()} files")
}

expect SbomFixtures.archive_name("0.7.0-rc1") == "roc-blueprint-sbom-fixtures-0.7.0-rc1"
expect SbomFixtures.files == Process.sorted(SbomFixtures.files) and SbomFixtures.files.contains("CONTRACT.md") and SbomFixtures.files.contains("source-import/expected.json")
expect SbomFixtures.files.all(|file| !file.starts_with("schema/"))

expect SbomFixtures.tracked("README.md\ntests/sbom/fixtures/input/Spec\ntests/sbom/schema/spdx-2.3.schema.json\ntests/sbom/fixtures/CONTRACT.md\n") == ["CONTRACT.md", "input/Spec"]
expect SbomFixtures.tracked_problem(SbomFixtures.files) == ""
expect SbomFixtures.tracked_problem(SbomFixtures.files.append("notes.txt")) == "scripts/src/SbomFixtures.roc must list exactly the tracked files of tests/sbom/fixtures (not listed: notes.txt; listed but untracked: )"
expect SbomFixtures.tracked_problem(SbomFixtures.files.keep_if(|file| file != "CONTRACT.md")).contains("listed but untracked: CONTRACT.md")
