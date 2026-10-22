import cli.Path
import cli.Cmd
import cli.OsStr
import core.Lock
import core.Spec
import CliHarness
import Integrity
import RocPackagesTest
import Script
import Serve
import "../../fixtures/consumer/authority.lock" as authority : Str

SourceFilesTest := [].{
	run! = |repository, real_build| {
		bench = CliHarness.open!(repository, "blueprint-source-files-", [])?
		server = Serve.open!()?
		result = cases!(bench, server, real_build)
		_ = server.shut!()
		CliHarness.close!(bench)
		result
	}
}

invoke! = |bench, server, root, args, cache| {
	match server.drive!([
		{
			cmd: Cmd.new(OsStr.from_str(bench.blueprint)).args(args.map(OsStr.from_str)).cwd(Path.utf8(root)).clear_envs().envs(CliHarness.setting(bench.env, [("ROC", bench.roc), ("BLUEPRINT_ROOT", root), ("BLUEPRINT_LOCK", "Blueprint.lock"), ("BLUEPRINT_TARGET", "x86_64-linux"), ("XDG_CACHE_HOME", cache)])),
			label: "source files ${Str.join_with(args, " ")}",
		},
	])? {
		[only] => Ok(only)
		_ => Script.fail!("missing source-file command result")
	}
}

config! = |bench, root, source, builds| {
	Path.create_all!(Path.utf8(root))?
	platform_path = RocPackagesTest.relative(root, "${bench.root}/blueprint-platform/main.roc")
	extra = if builds {
		"Packages(\"nixpkgs\", From(NixPackages(\"github:NixOS/nixpkgs/nixos-unstable\"))), Overlay(\"roc\", \"github:roc-lang/roc-overlay\"), Environment(\"base\", [Tools([\"nixpkgs#python3\"])]), Environment(\"dev\", [Overlays([\"roc\"])]), Executor(\"native\", Nix(\"nixpkgs\")), Build(\"copy\", [Execute(\"native\"), Use(\"base\"), Inputs([\"upstream\"]), Run([\"python3\", \"-c\", \"import hashlib, os; from pathlib import Path; data = (Path(os.environ[\\\"BLUEPRINT_INPUTS\\\"]) / \\\"upstream\\\").read_bytes(); Path(\\\"out\\\").write_text(hashlib.sha256(data).hexdigest())\"]), Output(\"out\")]),"
	} else ""
	Path.write_utf8!(Path.utf8("${root}/Blueprint.roc"), "app [config] { pf: platform \"${platform_path}\" }\nconfig = [Name(\"source-files\"), Systems([\"x86_64-linux\"]), SourceFile(\"upstream\", \"${source.url}\", \"${source.sha256}\"), ${extra}]\n")
}

cases! = |bench, idle, real_build| {
	bytes = [0x1f, 0x8b, 0x08, 0x00, 0xff, 0x00, 0x7f, 0x0a]
	server = idle.with_route("original.tar.gz", bytes)
	source = { name: "upstream", url: server.url("original.tar.gz"), sha256: Integrity.digest(bytes) }
	cache = "${bench.work}/cache"
	artifact = "${cache}/blueprint/v1/artifacts/sha256/${source.sha256}"
	root = "${bench.work}/resolve"
	config!(bench, root, source, False)?
	updated = invoke!(bench, server, root, ["update"], cache)?
	CliHarness.check!(updated.code == 0, "SourceFile update failed:\n${updated.stdout}${updated.stderr}")?
	lock_text = Path.read_utf8!(Path.utf8("${root}/Blueprint.lock"))?
	lock = Lock.parse(lock_text).map_err(|_| ScriptFailed)?
	CliHarness.check!(lock.sources == [Lock.file_pin(source)] and lock.fetched.is_empty() and Path.read_bytes!(Path.utf8(artifact))? == bytes, "flat pin or original bytes missing")?
	named = invoke!(bench, idle.emptied(), root, ["update", "upstream"], cache)?
	CliHarness.check!(named.code == 0 and Path.read_utf8!(Path.utf8("${root}/Blueprint.lock"))? == lock_text, "named file update changed a published pin or required a provider")?
	shown = invoke!(bench, idle.emptied(), root, ["lock", "show", "--json", "upstream"], cache)?
	CliHarness.check!(shown.code == 0 and shown.stdout.contains("\"digestKind\":\"file\"") and shown.stdout.contains("\"flatSha256\":\"${source.sha256}\"") and shown.stdout.contains("\"metadata\":{}"), "inspector conflated flat and NAR identities")?
	wrong = { ..source, sha256: "0000000000000000000000000000000000000000000000000000000000000000" }
	bad_root = "${bench.work}/wrong-published-hash"
	config!(bench, bad_root, wrong, False)?
	bad = invoke!(bench, server, bad_root, ["update"], cache)?
	CliHarness.check!(bad.code != 0 and bad.stderr.contains("SHA-256") and !CliHarness.present!("${bad_root}/Blueprint.lock"), "wrong published original-file hash was accepted or published")?
	# A normal Generate uses the same source operation as Build. Seed only
	# committed authority, then use a fresh cache; it must fetch known bytes
	# without re-resolving Nix or rewriting any pin.
	build_root = "${bench.work}/producer"
	config!(bench, build_root, source, True)?
	printed = invoke!(bench, server, build_root, ["spec"], cache)?
	CliHarness.check!(printed.code == 0, "producer Spec failed: ${printed.stderr}")?
	spec = Spec.parse(printed.stdout).map_err(|_| ScriptFailed)?
	pins = Lock.parse(authority).map_err(|_| ScriptFailed)?
	committed = { ..pins, intent: Lock.intent_of(spec), sources: pins.sources.append(Lock.file_pin(source)) }.to_str()
	Path.write_utf8!(Path.utf8("${build_root}/Blueprint.lock"), committed)?
	Path.delete!(Path.utf8(artifact))?
	cold = invoke!(bench, server, build_root, ["gen"], cache)?
	CliHarness.check!(cold.code == 0, "cold Generate failed: ${cold.stderr}")?
	flake = Path.read_utf8!(Path.utf8("${build_root}/.blueprint/flake.nix"))?
	CliHarness.check!(flake.contains("source-file-${source.sha256}.json") and Path.read_utf8!(Path.utf8("${build_root}/.blueprint/source-file-${source.sha256}.json"))? == Json.to_str(artifact) and flake.contains("recursive = false") and flake.contains("sha256 = \"${source.sha256}\"") and Path.read_bytes!(Path.utf8(artifact))? == bytes, "generated build did not expose original checked file")?
	named_with_nix = invoke!(bench, idle.emptied(), build_root, ["update", "upstream"], cache)?
	CliHarness.check!(named_with_nix.code == 0 and Path.read_utf8!(Path.utf8("${build_root}/Blueprint.lock"))? == committed, "named SourceFile update moved unrelated Nix pins")?
	warm = invoke!(bench, idle.emptied(), build_root, ["gen"], cache)?
	CliHarness.check!(warm.code == 0, "warm original file was not usable offline")?
	quoted_cache = "${bench.work}/cache with \"quotes\" and $".concat("{literal}")
	quoted = invoke!(bench, server, build_root, ["gen"], quoted_cache)?
	CliHarness.check!(quoted.code == 0, "cache path quoting failed: ${quoted.stderr}")?
	encoded_path = Path.read_utf8!(Path.utf8("${build_root}/.blueprint/source-file-${source.sha256}.json"))?
	decoded_path : Str
	decoded_path = Json.parse(encoded_path).map_err(|_| ScriptFailed)?
	CliHarness.check!(decoded_path == "${quoted_cache}/blueprint/v1/artifacts/sha256/${source.sha256}", "cache path was interpreted as executable syntax")?
	if real_build {
		first = invoke!(bench, server, build_root, ["build", "copy", "--json"], cache)?
		CliHarness.check!(first.code == 0, "original-file build failed: ${first.stderr}")?
		built : { provider : Str, build_identity : Str, metadata : { nix : { derivation : Str } }, outputs : List({ path : Str }) }
		built = Json.parse(first.stdout).map_err(|_| ScriptFailed)?
		CliHarness.check!(built.provider == "nix" and built.build_identity == built.metadata.nix.derivation and built.build_identity.ends_with(".drv"), "build did not report actual provider recipe identity")?
		CliHarness.check!(Path.read_utf8!(Path.utf8(built.outputs.first()?.path))? == source.sha256, "build did not receive the exact original file")?
		second_cache = "${bench.work}/other-cache-location"
		second = invoke!(bench, server, build_root, ["build", "copy", "--json"], second_cache)?
		CliHarness.check!(second.code == 0, "fresh-cache source build failed: ${second.stderr}")?
		rebuilt : { provider : Str, build_identity : Str, metadata : { nix : { derivation : Str } }, outputs : List({ path : Str }) }
		rebuilt = Json.parse(second.stdout).map_err(|_| ScriptFailed)?
		CliHarness.check!(rebuilt == built, "source-file cache location changed derivation or output identity")?
	}
	Path.write_utf8!(Path.utf8(artifact), "corrupt cached bytes")?
	repaired = invoke!(bench, server, build_root, ["gen"], cache)?
	CliHarness.check!(repaired.code == 0 and Path.read_bytes!(Path.utf8(artifact))? == bytes, "corrupt original file was not verified and repaired")?
	Path.delete!(Path.utf8(artifact))?
	wrong_server = idle.emptied().with_route("original.tar.gz", "wrong original archive".to_utf8())
	refused = invoke!(bench, wrong_server, build_root, ["gen"], cache)?
	CliHarness.check!(refused.code != 0 and refused.stderr.contains("SHA-256") and !CliHarness.present!(artifact), "wrong original bytes were accepted by normal Fetch")?
	CliHarness.check!(Path.read_utf8!(Path.utf8("${build_root}/Blueprint.lock"))? == committed, "ordinary source fetch changed committed authority")?
	Script.pass!("SourceFile checks published flat SHA-256 at resolve and fetch, keeps raw bytes, supports cold/warm/corrupt caches, refuses wrong originals, and exposes flat identity without changing authority")
}
