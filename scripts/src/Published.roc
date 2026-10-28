import cli.Path
import Bundle
import Process
import Script

## What is already released, and what the manual says about it.
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
		match assets.keep_if(|name| name.ends_with(".tar.zst") and !name.starts_with(Bundle.core_prefix) and !name.starts_with(Bundle.sbom_prefix)) {
			[one] => Ok(one)
			_ => Err(NoPlatformBundle)
		}

	## A first `Blueprint.roc`, as an AsciiDoc source block: the smallest
	## project, which takes nothing from Nix. `scripts/test_config.roc`
	## compiles it with the rest of the manual's Roc.
	snippet : Str -> Str
	snippet = |platform_url|
		Str.join_with(
			[
				"[source,roc]",
				"----",
				"app [config] { pf: platform \"${platform_url}\" }",
				"",
				"import pf.Recipes",
				"",
				"config = [",
				"	Name(\"my-project\"),",
				"	Environment(\"dev\", [",
				"		Programs([Fetch(\"roc-stable\", Recipes.roc_nightly(\"nightly-2026-10-28-bad769b\"))]),",
				"		Expect([\"git\"]),",
				"	]),",
				"	Shell(\"default\", [Use(\"dev\")]),",
				"	Task(\"version\", [Use(\"dev\"), Run([\"roc-stable\", \"version\"])]),",
				"	Task(\"status\", [Use(\"dev\"), Run([\"git\", \"status\", \"--short\"])]),",
				"]",
				"----",
				"",
			],
			"\n",
		)

	## The core bundle among a release's assets.
	core_asset : List(Str) -> Try(Str, [NoCoreBundle])
	core_asset = |assets|
		match assets.keep_if(|name| name.ends_with(".tar.zst") and name.starts_with(Bundle.core_prefix)) {
			[one] => Ok(one)
			_ => Err(NoCoreBundle)
		}

	## A release's tag and the names of its assets, as `gh` reports them.
	## `selector` is `latest` or `tags/<tag>`.
	Release : { tag : Str, assets : List(Str) }

	release! : Str, Str => Try(Release, _)
	release! = |root, selector| {
		api = "repos/${Bundle.repository!()}/releases/${selector}"
		tag = Process.succeed!(Process.command("gh", ["api", api, "--jq", ".tag_name"], root))?.stdout.trim()
		assets = Process.lines(Process.succeed!(Process.command("gh", ["api", api, "--jq", ".assets[].name"], root))?.stdout)
		Ok({ tag, assets })
	}

	## The URLs of the latest release's two bundles. Releases before 0.5.0
	## held the platform bundle alone and published the core package under a
	## `core-` tag of the same version.
	latest_bundles! : Str => Try({ tag : Str, platform_url : Str, core_url : Str }, _)
	latest_bundles! = |root| {
		repository = Bundle.repository!()
		latest = release!(root, "latest")?
		platform_url = match platform_asset(latest.assets) {
			Ok(asset) => Bundle.release_url(repository, latest.tag, asset)
			Err(NoPlatformBundle) => return Script.fail!("release ${latest.tag} of ${repository} does not hold exactly one platform bundle")
		}
		core_url = match core_asset(latest.assets) {
			Ok(asset) => Bundle.release_url(repository, latest.tag, asset)
			Err(NoCoreBundle) => {
				earlier = release!(root, "tags/core-${latest.tag}")?
				match platform_asset(earlier.assets) {
					Ok(asset) => Bundle.release_url(repository, earlier.tag, asset)
					Err(NoPlatformBundle) => return Script.fail!("neither release ${latest.tag} nor ${earlier.tag} of ${repository} holds a core bundle")
				}
			}
		}
		Ok({ tag: latest.tag, platform_url, core_url })
	}

	## Write the snippet for the latest published release, which `gh` reports.
	latest! : Str => Try({}, _)
	latest! = |root| {
		repository = Bundle.repository!()
		latest = release!(root, "latest")?
		match platform_asset(latest.assets) {
			Ok(asset) => write!(root, Bundle.release_url(repository, latest.tag, asset))
			Err(NoPlatformBundle) => Script.fail!("release ${latest.tag} of ${repository} does not hold exactly one platform bundle")
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

expect Published.core_asset(["3Cev8eY9.tar.zst", "roc-blueprint-core-DL8qEfet.tar.zst", "blueprint.sha256"]) == Ok("roc-blueprint-core-DL8qEfet.tar.zst")
expect Published.core_asset(["3Cev8eY9.tar.zst", "blueprint.sha256"]) == Err(NoCoreBundle)

expect Published.platform_asset(["3Cev8eY9.tar.zst", "roc-blueprint-sbom-ABC.tar.zst", "roc-blueprint-core-DEF.tar.zst"]) == Ok("3Cev8eY9.tar.zst")
