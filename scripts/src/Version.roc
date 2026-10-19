import cli.Env
import cli.OsStr
import cli.Path
import Bundle
import Process
import Published
import ReleaseNotes
import Script
import StaticChecks

## Whether a version may be released, checked before anything is built, and
## whether it is the right number for what changed, checked once the bundles
## exist.
Version := [].{

	## `X.Y.Z`, or `X.Y.Z-` and a suffix of letters, digits, dots and hyphens
	## for a release candidate.
	valid : Str -> Bool
	valid = |version|
		match version.split_on("-") {
			[numbers] => numeric(numbers)
			[numbers, .. as suffix] => numeric(numbers) and suffix.all(|part| !part.is_empty() and part.to_utf8().all(|byte| digit(byte) or letter(byte) or byte == '.'))
			[] => False
		}

	## The version a candidate is a candidate for: `roc bump` takes `X.Y.Z` alone.
	base : Str -> Str
	base = |version| version.split_on("-").first() ?? version

	## What a workflow step reads back through `$GITHUB_OUTPUT`.
	outputs : Str -> Str
	outputs = |version| "version=${version}\ntitle=${ReleaseNotes.title(version)}\nprerelease=${if ReleaseNotes.prerelease(version) "true" else "false"}\n"

	## Releases build with the newest official nightly, pinned in source. A
	## newer upstream release requires another reviewed update and test run.
	compiler_problem : Str, Str -> Str
	compiler_problem = |pinned, latest|
		if pinned.trim() == latest.trim() and pinned.trim().starts_with("nightly-") {
			""
		} else {
			"release compiler ${pinned.trim()} is not the latest nightly ${latest.trim()}; update the compiler pin and rerun the full suite"
		}

	## The version constants a release of `version` needs, or what is wrong.
	constants_problem : Str, Str, Str -> Str
	constants_problem = |version, flake, cli_source|
		match (StaticChecks.constant(flake, "version"), StaticChecks.constant(cli_source, "version")) {
			(Ok(packaged), Ok(reported)) =>
				if packaged == version and reported == version {
					""
				} else {
					"releasing ${version} needs version = \"${version}\" in flake.nix (now ${packaged}) and blueprint-cli/main.roc (now ${reported})"
				}
			_ => "flake.nix and blueprint-cli/main.roc must each set version"
		}

	## Refuse a version that cannot be released from this commit: one that is
	## malformed, has no notes, is already a tag or a release, or is not the
	## version the CLI and the flake report. A dry run releases nothing, so
	## only its notes are required.
	request! : Str, Str => Try({}, _)
	request! = |root, version| {
		dry_run = version == Bundle.dry_run_version
		compiler_tag = Path.read_utf8!(Path.utf8("${root}/blueprint-cli/compiler-version"))?.trim()
		Process.check!(valid(version), "${version} is not a version: expected X.Y.Z or X.Y.Z-rcN")?
		chapter = Path.read_utf8!(Path.utf8("${root}/docs/releases.adoc"))?
		authored = match ReleaseNotes.noted(version, chapter) {
			Ok(noted) => ReleaseNotes.notes_file(noted)
			Err(NoNotes) => return Script.fail!("docs/releases.adoc includes no release notes")
		}
		Process.check!(Path.is_file!(Path.utf8("${root}/${authored}")) ?? False, "${authored} does not exist: write the notes of ${version} before releasing it")?
		Process.check!(dry_run or chapter.contains("include::releases/${base(version)}.adoc["), "docs/releases.adoc does not include ${authored}")?
		if !dry_run {
			flake = Path.read_utf8!(Path.utf8("${root}/flake.nix"))?
			cli_source = Path.read_utf8!(Path.utf8("${root}/blueprint-cli/main.roc"))?
			reason = constants_problem(version, flake, cli_source)
			Process.check!(reason.is_empty(), reason)?
			latest = Process.succeed!(Process.command("gh", ["api", "repos/roc-lang/nightlies/releases/latest", "--jq", ".tag_name"], root))?.stdout
			Process.check!(compiler_problem(compiler_tag, latest).is_empty(), compiler_problem(compiler_tag, latest))?
			unpublished!(root, version)?
		}
		Script.pass!("${version} may be released with ${authored}")?
		match Env.var_str!(OsStr.from_str("GITHUB_OUTPUT")) {
			Ok(file) => {
				earlier = if Path.exists!(Path.utf8(file))? Path.read_utf8!(Path.utf8(file))? else ""
				Path.write_utf8!(Path.utf8(file), "${earlier}${outputs(version)}compiler-tag=${compiler_tag}\n")
			}
			Err(_) => Ok({})
		}
	}

	## Compare the public API of the core package, and of the platform as
	## `scripts/bundle.roc` bundled it, with the latest release. A release
	## fails unless `version` bumps at least as far as the difference
	## requires; a dry run reports the required bump.
	bump! : Str, Str => Try({}, _)
	bump! = |root, version| {
		work = Path.to_str(Path.canonicalize!(Env.create_temp_dir_with_prefix!("blueprint-bump-")?)?)?
		result = compared!(root, version, work)
		_ = Path.delete_all!(Path.utf8(work))
		result
	}
}

digit : U8 -> Bool
digit = |byte| byte >= '0' and byte <= '9'

letter : U8 -> Bool
letter = |byte| (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z')

numeric : Str -> Bool
numeric = |numbers| {
	parts = numbers.split_on(".")
	parts.len() == 3 and parts.all(|part| !part.is_empty() and part.to_utf8().all(digit))
}

## Neither a tag nor a release of this version exists. `gh release create`
## refuses an existing release; a tag alone would be silently reused.
unpublished! : Str, Str => Try({}, _)
unpublished! = |root, version| {
	repository = Bundle.repository!()
	tags = Process.succeed!(Process.command("gh", ["api", "repos/${repository}/git/matching-refs/tags/${version}", "--jq", ".[].ref"], root))?
	Process.check!(!Process.lines(tags.stdout).contains("refs/tags/${version}"), "the tag ${version} already exists in ${repository}")?
	releases = Process.succeed!(Process.command("gh", ["api", "repos/${repository}/releases", "--paginate", "--jq", ".[].tag_name"], root))?
	Process.check!(!Process.lines(releases.stdout).contains(version), "the release ${version} already exists in ${repository}")
}

compared! : Str, Str, Str => Try({}, _)
compared! = |root, version, work| {
	list = Path.read_utf8!(Path.utf8("${root}/dist/bundles.txt"))?
	(platform_bundle, core_bundle) = match (Bundle.archive(list, "roc-blueprint"), Bundle.archive(list, "roc-blueprint-core")) {
		(Ok(first), Ok(second)) => (first, second)
		_ => return Script.fail!("dist/bundles.txt does not list both bundles: run scripts/bundle.roc ${version}")
	}
	previous = Published.latest_bundles!(root)?
	expected = if version == Bundle.dry_run_version [] else ["--expect", Version.base(version)]
	roc = Process.roc!()

	Script.info!("==>", "roc-blueprint-core against ${previous.core_url}")?
	core = Process.succeed!(Process.command(roc, ["bump", "--old", previous.core_url].concat(expected).concat(["${Bundle.core_dir}/main.roc"]), root))?
	Script.info!("   ", core.stdout.trim())?

	# The platform in the working tree names the core package by path, which
	# `roc bump` refuses in a public type. The bundled platform names it by
	# the URL it will have, which does not exist yet: the compiler finds it in
	# a package cache that already holds it, under its hash.
	Script.info!("==>", "roc-blueprint, as bundled, against ${previous.platform_url}")?
	core_hashed = core_bundle.drop_prefix(Bundle.core_prefix)
	unpacked = "${work}/unpacked"
	package_cache = "${work}/cache/roc/packages"
	Path.create_all!(Path.utf8(unpacked))?
	Path.create_all!(Path.utf8(package_cache))?
	# `roc unbundle` checks an archive against the hash that is its whole name.
	Path.copy!(Path.utf8("${root}/dist/${platform_bundle}"), Path.utf8("${unpacked}/${platform_bundle}"))?
	Path.copy!(Path.utf8("${root}/dist/${core_bundle}"), Path.utf8("${unpacked}/${core_hashed}"))?
	_ = Process.succeed!(Process.command(roc, ["unbundle", platform_bundle, core_hashed], unpacked))?
	Path.rename!(Path.utf8("${unpacked}/${core_hashed.drop_suffix(".tar.zst")}"), Path.utf8("${package_cache}/${core_hashed.drop_suffix(".tar.zst")}"))?
	entry = "${platform_bundle.drop_suffix(".tar.zst")}/main.roc"
	compared = Process.succeed!(
		Process.with_env(
			# The bundle holds every target's linker inputs.
			Process.command(roc, ["bump", "--old", previous.platform_url, "--max-package-mb=0"].concat(expected).concat([entry]), unpacked),
			[("XDG_CACHE_HOME", "${work}/cache")],
		),
	)?
	Script.info!("   ", compared.stdout.trim())?
	Script.pass!("compared both packages with release ${previous.tag}")
}

expect Version.valid("0.5.0") and Version.valid("0.5.0-rc1") and Version.valid(Bundle.dry_run_version)
expect !Version.valid("0.5") and !Version.valid("v0.5.0") and !Version.valid("0.5.0-") and !Version.valid("0.5.0--rc1") and !Version.valid("0.5.x") and !Version.valid("core-0.5.0") and !Version.valid("")
expect !Version.valid("0.5.0-rc1; rm")

expect Version.base("0.5.0-rc1") == "0.5.0" and Version.base("0.5.0") == "0.5.0"
expect Version.outputs("0.5.0-rc1") == "version=0.5.0-rc1\ntitle=roc-blueprint 0.5.0-rc1\nprerelease=true\n"
expect Version.outputs("0.5.0") == "version=0.5.0\ntitle=roc-blueprint 0.5.0\nprerelease=false\n"

expect Version.constants_problem("0.5.0", "  version = \"0.5.0\";\n", "version = \"0.5.0\"\n") == ""
expect Version.constants_problem("0.5.0", "  version = \"0.4.1\";\n", "version = \"0.5.0\"\n") == "releasing 0.5.0 needs version = \"0.5.0\" in flake.nix (now 0.4.1) and blueprint-cli/main.roc (now 0.5.0)"
expect Version.constants_problem("0.5.0", "", "version = \"0.5.0\"\n") != ""

expect Version.compiler_problem("nightly-new\n", "nightly-new\n") == ""
expect Version.compiler_problem("nightly-old", "nightly-new") != ""
expect Version.compiler_problem("", "") != ""
expect Version.compiler_problem("latest", "latest") != ""
