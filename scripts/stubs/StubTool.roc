import nix.LockJson

## What the stub tool does that needs no effects: which program it stands in
## for, the record it keeps of each invocation, and the native lock graphs its
## `nix` fabricates. The tests read the records with the same functions.
StubTool := [].{

	## The program a copy stands in for.
	Role : [RocRecord, RocWire, RocProbe, Nix, Guix, Python, Readlink]

	## The file names a copy may be installed under.
	names : List(Str)
	names = ["roc-record", "roc-wire", "roc-probe", "nix", "guix", "python3", "readlink"]

	## The role of an executable, from the last part of its resolved path. A
	## symbolic link called `roc` therefore takes the role of its target.
	role : Str -> Try(Role, [UnknownRole(Str)])
	role = |executable| {
		name = executable.split_on("/").last() ?? executable
		match name {
			"roc-record" => Ok(RocRecord)
			"roc-wire" => Ok(RocWire)
			"roc-probe" => Ok(RocProbe)
			"nix" => Ok(Nix)
			"guix" => Ok(Guix)
			"python3" => Ok(Python)
			"readlink" => Ok(Readlink)
			_ => Err(UnknownRole(name))
		}
	}

	## One invocation's arguments as a line of JSON.
	record : List(Str) -> Str
	record = |argv| "${LockJson.encode(LockJson.Array(argv.map(|arg| LockJson.String(arg))))}\n"

	## The arguments a record holds.
	parse_record : Str -> Try(List(Str), Str)
	parse_record = |text| {
		items = LockJson.array(LockJson.decode(text.trim())?)?
		var $argv = []
		for item in items {
			$argv = $argv.append(LockJson.string(item)?)
		}
		Ok($argv)
	}

	## A record's file name: the time in nanoseconds, padded so that names sort
	## in the order the invocations started, then the process identifier. Two
	## processes therefore never write the same file.
	record_file : U128, Str -> Str
	record_file = |nanos, pid| {
		digits = nanos.to_str()
		width = digits.to_utf8().len()
		padding = Str.join_with(List.repeat("0", if width < 24 24 - width else 0), "")
		"${padding}${digits}-${pid}.json"
	}

	## The flake inputs a generated `flake.nix` declares, in order.
	declared : Str -> List({ name : Str, url : Str })
	declared = |flake| {
		var $inputs = []
		for line in flake.split_on("\n") {
			match line.trim().split_on("\" = { url = \"") {
				[left, right] => {
					if left.starts_with("\"") and right.ends_with("\"; flake = true; };") {
						$inputs = $inputs.append({ name: left.drop_prefix("\""), url: right.drop_suffix("\"; flake = true; };") })
					}
				}
				_ => {}
			}
		}
		$inputs
	}

	## The node of the consumer fixture that pins a declared URL.
	pin : Str -> Try(Str, Str)
	pin = |url|
		match url {
			"github:NixOS/nixpkgs/nixos-unstable" => Ok("nixpkgs")
			"github:example/unused-overlay" => Ok("foreign-overlay")
			_ => Err("the stub has no fixture pin for ${url}")
		}

	## A native lock for the declared inputs, from the consumer fixture's real
	## pins. The overlay is invented: no Nix evaluation is claimed.
	declared_graph : Str, List({ name : Str, url : Str }) -> Try(Str, Str)
	declared_graph = |fixture, inputs| {
		if inputs.is_empty() {
			return Err("stub expected the fixture's declared flake inputs")
		}
		graph = LockJson.decode(fixture)?
		nodes = LockJson.field(graph, "nodes")?
		nar_hash = LockJson.field(LockJson.field(LockJson.field(nodes, "nixpkgs")?, "locked")?, "narHash")?
		overlay = [text("type", "github"), text("owner", "example"), text("repo", "unused-overlay")]
		foreign = LockJson.Object([
			{ name: "original", value: LockJson.Object(overlay) },
			{ name: "locked", value: LockJson.Object(overlay.concat([text("rev", repeated("a")), { name: "narHash", value: nar_hash }])) },
		])
		var $root_inputs = []
		for input in inputs {
			$root_inputs = $root_inputs.append(text(input.name, pin(input.url)?))
		}
		root = LockJson.set(LockJson.field(nodes, "root")?, "inputs", LockJson.Object($root_inputs))?
		pinned = LockJson.set(LockJson.set(nodes, "foreign-overlay", foreign)?, "root", root)?
		Ok(LockJson.encode(LockJson.set(graph, "nodes", pinned)?))
	}

	## A native lock from the provider's local fixture without its `assets`
	## input, whose `default` revision is `letter` forty times.
	local_graph : Str, Str -> Try(Str, Str)
	local_graph = |fixture, letter| {
		graph = LockJson.decode(fixture)?
		nodes = LockJson.field(graph, "nodes")?
		root = LockJson.field(nodes, "root")?
		root_inputs = without(LockJson.field(root, "inputs")?, "assets")?
		default = LockJson.field(nodes, "default")?
		locked = LockJson.set(LockJson.field(default, "locked")?, "rev", LockJson.String(repeated(letter)))?
		pinned = LockJson.set(
			LockJson.set(without(nodes, "assets")?, "default", LockJson.set(default, "locked", locked)?)?,
			"root",
			LockJson.set(root, "inputs", root_inputs)?,
		)?
		Ok(LockJson.encode(LockJson.set(graph, "nodes", pinned)?))
	}
}

text : Str, Str -> { name : Str, value : LockJson }
text = |name, value| { name, value: LockJson.String(value) }

repeated : Str -> Str
repeated = |letter| Str.join_with(List.repeat(letter, 40), "")

without : LockJson, Str -> Try(LockJson, Str)
without = |value, name| Ok(LockJson.Object(LockJson.object(value)?.keep_if(|entry| entry.name != name)))

expect StubTool.role("/tmp/work/bin/roc-record") == Ok(RocRecord)
expect StubTool.role("nix") == Ok(Nix)
expect StubTool.role("/tmp/work/bin/roc") == Err(UnknownRole("roc"))
expect StubTool.names.all(|name| StubTool.role("/bin/${name}").is_ok())

expect StubTool.record(["develop", "two words", "line\nbreak", "a'b\"c", ""]) == "[\"develop\",\"two words\",\"line\\u000abreak\",\"a'b\\\"c\",\"\"]\n"
expect StubTool.parse_record(StubTool.record(["develop", "two words", "line\nbreak", "a'b\"c", ""])) == Ok(["develop", "two words", "line\nbreak", "a'b\"c", ""])
expect StubTool.parse_record(StubTool.record([])) == Ok([])
expect StubTool.parse_record("{}").is_err() and StubTool.parse_record("[1]").is_err()

expect StubTool.record_file(1791278060201687237, "42") == "000001791278060201687237-42.json"
expect StubTool.record_file(9, "1") == "000000000000000000000009-1.json"

expect StubTool.declared(
	\\  inputs = {
	\\    "default" = { url = "github:NixOS/nixpkgs/nixos-unstable"; flake = true; };
	\\    "assets" = { url = "path:/project/assets"; flake = false; };
	\\    "foreign-overlay" = { url = "github:example/unused-overlay"; flake = true; };
	\\  };
	,
) == [
	{ name: "default", url: "github:NixOS/nixpkgs/nixos-unstable" },
	{ name: "foreign-overlay", url: "github:example/unused-overlay" },
]

consumer_fixture : Str
consumer_fixture =
	\\{"nodes":{"nixpkgs":{"locked":{"narHash":"sha256-abc","rev":"r"}},"other":{},"root":{"inputs":{"nixpkgs":"nixpkgs","roc":"roc"}}},"root":"root","version":7}

expect StubTool.declared_graph(consumer_fixture, []).is_err()
expect StubTool.declared_graph(consumer_fixture, [{ name: "utils", url: "github:numtide/flake-utils" }]) == Err("the stub has no fixture pin for github:numtide/flake-utils")
expect StubTool.declared_graph(
	consumer_fixture,
	[{ name: "default", url: "github:NixOS/nixpkgs/nixos-unstable" }, { name: "foreign-overlay", url: "github:example/unused-overlay" }],
) == Ok(
	"{\"root\":\"root\",\"version\":7,\"nodes\":{\"nixpkgs\":{\"locked\":{\"narHash\":\"sha256-abc\",\"rev\":\"r\"}},\"other\":{},"
		.concat("\"foreign-overlay\":{\"original\":{\"type\":\"github\",\"owner\":\"example\",\"repo\":\"unused-overlay\"},")
		.concat("\"locked\":{\"type\":\"github\",\"owner\":\"example\",\"repo\":\"unused-overlay\",\"rev\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"narHash\":\"sha256-abc\"}},")
		.concat("\"root\":{\"inputs\":{\"default\":\"nixpkgs\",\"foreign-overlay\":\"foreign-overlay\"}}}}"),
)

local_fixture : Str
local_fixture =
	\\{"nodes":{"assets":{"flake":false},"default":{"locked":{"rev":"old","type":"github"}},"root":{"inputs":{"assets":"assets","default":"default"}}},"root":"root","version":7}

expect StubTool.local_graph(local_fixture, "b") == Ok(
	"{\"root\":\"root\",\"version\":7,\"nodes\":{\"default\":{\"locked\":{\"type\":\"github\",\"rev\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"}},"
		.concat("\"root\":{\"inputs\":{\"default\":\"default\"}}}}"),
)
