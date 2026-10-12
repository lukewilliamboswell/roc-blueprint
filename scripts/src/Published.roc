import cli.Path
import Bundle
import Process
import Script

## What the manual says about the latest release.
##
## The first program a reader copies names a release's platform bundle, whose
## URL holds a hash no committed file can know. `docs/generated/` is written
## before the manual is rendered and is not committed.
Published := [].{

	## The file the Get started chapter includes.
	snippet_file = "docs/generated/latest-release.adoc"

	## The platform bundle among a release's assets: the one archive named by
	## its hash alone. The core package's carries a prefix.
	platform_asset : List(Str) -> Try(Str, [NoPlatformBundle])
	platform_asset = |assets|
		match assets.keep_if(|name| name.ends_with(".tar.zst") and !name.starts_with(Bundle.core_prefix)) {
			[one] => Ok(one)
			_ => Err(NoPlatformBundle)
		}

	## A first `Blueprint.roc`, as an AsciiDoc source block.
	snippet : Str -> Str
	snippet = |platform_url|
		Str.join_with(
			[
				"[source,roc]",
				"----",
				"app [config] { pf: platform \"${platform_url}\" }",
				"",
				"config = [",
				"	Name(\"my-project\"),",
				"	Systems([\"x86_64-linux\", \"aarch64-linux\", \"aarch64-darwin\"]),",
				"	Overlay(\"roc\", \"github:roc-lang/roc-overlay\"),",
				"	Environment(\"base\", [Tools([\"git\", \"zig\"])]),",
				"	Environment(\"dev\", [",
				"		Extend(\"base\"),",
				"		Tools([\"rocpkgs.nightly\", \"python3\", \"sqlite\"]),",
				"		Overlays([\"roc\"]),",
				"	]),",
				"	Shell(\"default\", [Use(\"dev\")]),",
				"	Shell(\"ci\", [Use(\"base\")]),",
				"	Task(\"version\", [Use(\"dev\"), Run([\"python3\", \"--version\"])]),",
				"	Task(\"check\", [Use(\"base\"), Run([\"git\", \"--version\"])]),",
				"]",
				"----",
				"",
			],
			"\n",
		)

	## Write the snippet for the latest published release, which `gh` reports.
	latest! : Str => Try({}, _)
	latest! = |root| {
		repository = Bundle.repository!()
		release = "repos/${repository}/releases/latest"
		tag = Process.succeed!(Process.command("gh", ["api", release, "--jq", ".tag_name"], root))?.stdout.trim()
		assets = Process.lines(Process.succeed!(Process.command("gh", ["api", release, "--jq", ".assets[].name"], root))?.stdout)
		match platform_asset(assets) {
			Ok(asset) => write!(root, Bundle.release_url(repository, tag, asset))
			Err(NoPlatformBundle) => Script.fail!("release ${tag} of ${repository} does not hold exactly one platform bundle")
		}
	}

	## Write the snippet for the release of `version` being built, from the
	## bundles `scripts/bundle.roc` made for it.
	built! : Str, Str => Try({}, _)
	built! = |root, version| {
		list = Path.read_utf8!(Path.utf8("${root}/dist/bundles.txt"))?
		match Bundle.archive(list, "roc-blueprint") {
			Ok(asset) => write!(root, Bundle.release_url(Bundle.repository!(), version, asset))
			Err(NotBundled(_)) => Script.fail!("dist/bundles.txt does not list roc-blueprint: run scripts/bundle.roc ${version}")
		}
	}
}

write! : Str, Str => Try({}, _)
write! = |root, platform_url| {
	file = "${root}/${Published.snippet_file}"
	Path.create_all!(Path.utf8(Str.join_with(file.split_on("/").drop_last(1), "/")))?
	Path.write_utf8!(Path.utf8(file), Published.snippet(platform_url))?
	Script.pass!("wrote ${Published.snippet_file} for ${platform_url}")
}

expect Published.platform_asset(["3Cev8eY9.tar.zst", "roc-blueprint-core-DL8qEfet.tar.zst", "blueprint-x86_64-linux", "blueprint.sha256"]) == Ok("3Cev8eY9.tar.zst")

# Releases before 0.5.0 held the platform bundle alone.
expect Published.platform_asset(["3Cev8eY9.tar.zst", "blueprint.sha256"]) == Ok("3Cev8eY9.tar.zst")
expect Published.platform_asset(["blueprint-x86_64-linux"]) == Err(NoPlatformBundle)
expect Published.platform_asset(["a.tar.zst", "b.tar.zst"]) == Err(NoPlatformBundle)

expect Published.snippet("https://example.test/a.tar.zst").starts_with("[source,roc]\n----\napp [config] { pf: platform \"https://example.test/a.tar.zst\" }\n")
expect Published.snippet("u").ends_with("]\n----\n")
