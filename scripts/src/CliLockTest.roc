import cli.Path
import nix.LockJson
import CliHarness
import Script
import "../../fixtures/consumer/authority.lock" as authority : Str

CliLockTest := [].{
	run! : Path => Try({}, _)
	run! = |repository| {
		bench = CliHarness.open!(repository, "blueprint-lock-", [])?
		result = cases!(bench)
		CliHarness.close!(bench)
		result
	}
}

cases! = |bench| {
	cwd = "${bench.work}/project"
	cache = "${bench.work}/cache"
	Path.create_all!(Path.utf8(cwd))?
	file = Path.utf8("${cwd}/Blueprint.lock")
	Path.write_utf8!(file, authority)?
	Path.write_utf8!(Path.utf8("${cwd}/Blueprint.roc"), "deliberately invalid; must never evaluate")?
	env = CliHarness.setting(
		bench.env,
		[
			("PATH", ""),
			("ROC", "missing-compiler"),
			("BLUEPRINT_ROOT", cwd),
			("BLUEPRINT_LOCK", "Blueprint.lock"),
			("BLUEPRINT_WORKSPACE", "missing/state"),
			("BLUEPRINT_GENERATED_ROOT", "missing/generated"),
			("BLUEPRINT_TARGET", "not-a-host"),
			("XDG_CACHE_HOME", cache),
		],
	)
	call = { program: bench.blueprint, args: ["lock", "show", "--json", "nixpkgs"], cwd, env }
	query = CliHarness.invoke!(call)?
	CliHarness.exited!(query, 0, "offline lock show")?
	decoded = LockJson.decode(query.stdout).map_err(|_| ScriptFailed)?
	pin = LockJson.field(LockJson.field(decoded, "sources").map_err(|_| ScriptFailed)?, "nixpkgs").map_err(|_| ScriptFailed)?
	fetch = LockJson.field(pin, "fetchTree").map_err(|_| ScriptFailed)?
	CliHarness.check!(LockJson.field(fetch, "rev") == Ok(LockJson.String("4975466d324710c576dc11ad614684e6bd8cad8e")) and LockJson.field(fetch, "narHash") == Ok(LockJson.String("sha256-xJ+X4hBtOcAFGBOe5nAMyMUeF9foJBmIOu3NjBqBycU=")) and query.stderr == "", "inspector did not expose exact committed pin")?
	CliHarness.check!(Path.read_utf8!(file)? == authority and !CliHarness.present!(cache) and !CliHarness.present!("${cwd}/missing") and !CliHarness.present!("${cwd}/.blueprint"), "inspector changed authority or created state")?
	Path.write_utf8!(file, authority.replace_each("(minor 1)", "(minor 9)"))?
	future = CliHarness.invoke!(call)?
	CliHarness.check!(future.code == 0 and future.stdout == query.stdout, "minor lock format bump changed the selected pin")?
	Path.write_utf8!(file, authority.replace_each("sha256:c49f97e2106d39c00518139ee6700cc8c51e17d7e82419883aedcd8c1a81c9c5", "sha256:0000000000000000000000000000000000000000000000000000000000000000"))?
	tampered = CliHarness.invoke!(call)?
	CliHarness.check!(tampered.code == 1 and tampered.stdout == "" and tampered.stderr.contains("do not match"), "inspector accepted sources that disagree with provider pins")?
	Path.write_utf8!(file, authority)?
	all = CliHarness.invoke!({ ..call, args: ["lock", "show", "--json"] })?
	CliHarness.exited!(all, 0, "all locked entries")?
	CliHarness.contains!(all.stdout, "\"roc\"", "all source names")?
	text = CliHarness.invoke!({ ..call, args: ["lock", "show", "nixpkgs"] })?
	CliHarness.exited!(text, 0, "text lock show")?
	CliHarness.contains!(text.stdout, "source nixpkgs [nix]", "text lock report")?
	unknown = CliHarness.invoke!({ ..call, args: ["lock", "show", "--json", "missing"] })?
	CliHarness.check!(unknown.code == 1 and unknown.stdout == "" and unknown.stderr.contains("unknown locked entry"), "unknown source was silently accepted")?
	help = CliHarness.invoke!({ ..call, args: ["lock", "show", "--help"] })?
	CliHarness.exited!(help, 0, "lock help")?
	invalid = CliHarness.invoke!({ ..call, args: ["lock", "wrong"] })?
	CliHarness.exited!(invalid, 2, "invalid lock usage")?
	# An alternate lock path works without any Blueprint.roc in that root.
	Path.write_utf8!(Path.utf8("${bench.work}/pins.lock"), authority)?
	alternate = CliHarness.invoke!({ ..call, env: CliHarness.setting(env, [("BLUEPRINT_ROOT", bench.work), ("BLUEPRINT_LOCK", "pins.lock")]) })?
	CliHarness.check!(alternate.code == 0 and alternate.stdout == query.stdout, "alternate lock path required a project")?
	Path.write_utf8!(file, "not a lock")?
	bad = CliHarness.invoke!(call)?
	CliHarness.check!(bad.code == 1 and bad.stdout == "", "malformed lock accepted")?
	Path.delete!(file)?
	missing = CliHarness.invoke!(call)?
	CliHarness.check!(missing.code == 1 and missing.stdout == "", "absent lock accepted")?
	Script.pass!("lock show exposes exact pins offline, ignores malformed/absent config, creates no state, respects lock path overrides, and refuses missing/malformed entries")
}
