# Generate build snapshots: small node graphs with cycles, dangling dependencies and arbitrary text.
app [target] {
	core: "../../main.roc",
	pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst",
}

import pf.Fuzz
import core.BuildModel
import core.Tree

## Two snapshots, the second of any shape, and the parts of a build record.
Case : { a : BuildModel.Snapshot, b : BuildModel.Snapshot, version : U64, build_identity : Str, outputs : List({ name : Str, path : Str }), tidy : Bool }

## `compare(a, a)` must be `Ok([])` for a well-formed `a`; `compare` must
## return a result for any pair; `dependency_path`, reached only through
## `validate` and `compare`, must terminate (the target must finish); a record
## `validate` accepts must survive `render_record` then `parse_record`; and
## `digest` must be stable and change when a file digest changes, which
## `compare` must then report.
test : Case -> Fuzz.Outcome
test = |case| {
	a = case.a
	if BuildModel.compare(a, a) != Ok([]) {
		crash "a well-formed snapshot differs from itself"
	}
	_ = BuildModel.compare(a, case.b)
	_ = BuildModel.compare(case.b, a)
	_ = BuildModel.compare(case.b, case.b)
	record = { schema_version: case.version, snapshot: if (case.tidy) tidy(a) else a, build_identity: case.build_identity, outputs: case.outputs }
	record_checked = if (case.tidy) tidy_record(record) else record
	for candidate in [record_checked, { ..record_checked, snapshot: case.b }] {
		match BuildModel.validate(candidate) {
			Ok({}) =>
				match BuildModel.render_record(candidate) {
					Ok(text) =>
						if BuildModel.parse_record(text) != Ok(candidate) {
							crash "a valid build record did not survive a render and parse"
						}
					Err(message) => crash "a valid build record was refused on render: ${message}"
				}
			Err(_) => {}
		}
	}
	if BuildModel.digest(a) != BuildModel.digest(a) {
		crash "snapshot digest is not stable"
	}
	match changed_file(a) {
		Ok({ snapshot: changed, node, path }) => {
			if BuildModel.digest(changed) == BuildModel.digest(a) {
				crash "snapshot digest ignored a changed file digest"
			}
			reported = BuildModel.compare(a, changed).map_ok(|changes| changes.any(|change| change.build == node and change.kind == "file-changed" and change.name == path))
			if reported != Ok(True) {
				crash "compare did not report a changed file digest"
			}
		}
		Err(NoFile) => {}
	}
	Fuzz.keep
}

## `snapshot` with the digest of its first file changed, and where.
changed_file : BuildModel.Snapshot -> Try({ snapshot : BuildModel.Snapshot, node : Str, path : Str }, [NoFile])
changed_file = |snapshot| {
	owner = snapshot.nodes.find_first(|node| !node.files.is_empty()).map_err(|_| NoFile)?
	file = owner.files.first().map_err(|_| NoFile)?
	nodes = snapshot.nodes.map(
		|node|
			if node.name == owner.name {
				{ ..node, files: node.files.map(|entry| if (entry.path == file.path) { ..entry, digest: "${entry.digest}x" } else entry) }
			} else {
				node
			},
	)
	Ok({ snapshot: { ..snapshot, nodes }, node: owner.name, path: file.path })
}

## The first of the items with each key.
unique_by : List(a), (a -> k) -> List(a) where [k.is_eq : k, k -> Bool]
unique_by = |items, key| items.fold([], |kept, item| if (kept.any(|other| key(other) == key(item))) kept else kept.append(item))

## Unique node names, and unique file paths and input names in each node:
## what `compare` relies on. Cycles and dangling dependencies stay.
well_formed : BuildModel.Snapshot -> BuildModel.Snapshot
well_formed = |snapshot| {
	..snapshot,
	nodes: unique_by(snapshot.nodes, |node| node.name).map(|node| { ..node, files: unique_by(node.files, |file| file.path), inputs: unique_by(node.inputs, |input| input.name) }),
}

filled : Str -> Str
filled = |text| if (text.is_empty()) "x" else text

## A well-formed snapshot nudged toward what `validate` accepts: no empty
## fields, valid paths, only known dependencies and the selected build
## present. Cycles and unreachable nodes remain.
tidy : BuildModel.Snapshot -> BuildModel.Snapshot
tidy = |snapshot| {
	names = snapshot.nodes.map(|node| node.name)
	nodes = snapshot.nodes.map(
		|node| {
			..node,
			command: if (node.command.is_empty()) ["x"] else node.command,
			environment: filled(node.environment),
			executor: filled(node.executor),
			output: filled(node.output),
			declarations: filled(node.declarations),
			dependencies: node.dependencies.keep_if(|name| names.contains(name)),
			files: node.files.keep_if(|file| Tree.check_path(file.path).is_ok()).map(|file| { ..file, digest: filled(file.digest) }),
			inputs: node.inputs.map(|input| { name: filled(input.name), provider: filled(input.provider), content_identity: filled(input.content_identity) }),
		},
	)
	{ ..snapshot, name: names.first() ?? snapshot.name, provider: filled(snapshot.provider), nodes: unique_by(nodes, |node| node.name).map(|node| { ..node, inputs: unique_by(node.inputs, |input| input.name) }) }
}

tidy_record : BuildModel.Record -> BuildModel.Record
tidy_record = |record| {
	..record,
	schema_version: 1,
	build_identity: filled(record.build_identity),
	outputs: (if (record.outputs.is_empty()) [{ name: "out", path: "/out" }] else record.outputs).map(|output| { name: filled(output.name), path: filled(output.path) }),
}

## One of `choices`, or any text.
from : List(Str) -> Fuzz.Generator(Str)
from = |choices| |state| {
	choice = Fuzz.u8_in(0, U64.to_u8_wrap(choices.len() + 1))(state)
	match choices.get(choice.value.to_u64()) {
		Ok(word) => Fuzz.constant(word)(choice.state)
		Err(_) => Fuzz.str(choice.state)
	}
}

## Node names from a small pool, so dependencies meet, cycle and dangle.
node_name : Fuzz.Generator(Str)
node_name = from(["a", "b", "c", "d", ""])

text : Fuzz.Generator(Str)
text = from(["x", "dev", "native", ""])

path : Fuzz.Generator(Str)
path = from(["lib.c", "src/main.c", "a/../b", "/abs", ""])

node : Fuzz.Generator(BuildModel.Node)
node = Fuzz.map(
	{
		name: node_name,
		selected_files: Fuzz.u8_in(0, 1),
		command: Fuzz.list(text, 2),
		environment: text,
		executor: text,
		output: text,
		dependencies: Fuzz.list(node_name, 3),
		declarations: text,
		files: Fuzz.list({ path, digest: text }.Fuzz, 2),
		inputs: Fuzz.list({ name: text, provider: text, content_identity: text }.Fuzz, 2),
	}.Fuzz,
	|r| { name: r.name, selected_files: r.selected_files == 1, command: r.command, environment: r.environment, executor: r.executor, output: r.output, dependencies: r.dependencies, declarations: r.declarations, files: r.files, inputs: r.inputs },
)

snapshot : Fuzz.Generator(BuildModel.Snapshot)
snapshot = { name: node_name, system: text, provider: text, nodes: Fuzz.list(node, 5) }.Fuzz

case_generator : Fuzz.Generator(Case)
case_generator = Fuzz.map(
	{
		a: snapshot,
		other: snapshot,
		shape: Fuzz.u8_in(0, 2),
		version: Fuzz.u8_in(0, 3),
		build_identity: text,
		outputs: Fuzz.list({ name: text, path: text }.Fuzz, 2),
		tidy: Fuzz.u8_in(0, 1),
	}.Fuzz,
	|r| {
		a = well_formed(r.a)
		# The second snapshot is unconstrained: another build, or the same
		# build with other nodes, perhaps sharing names with the first.
		b = match r.shape {
			0 => r.other
			1 => { ..a, nodes: r.other.nodes }
			_ => { ..a, nodes: a.nodes.concat(r.other.nodes) }
		}
		{ a, b, version: if (r.version == 0) 2 else 1, build_identity: r.build_identity, outputs: r.outputs, tidy: r.tidy == 1 }
	},
)

target = Fuzz.target_with({
	name: "build-model-compare",
	generator: case_generator,
	test,
	show: |case| "a: ${Str.inspect(case.a)}\nb: ${Str.inspect(case.b)}\nversion: ${case.version.to_str()} identity: ${Str.inspect(case.build_identity)} outputs: ${Str.inspect(case.outputs)} tidy: ${Str.inspect(case.tidy)}",
})
