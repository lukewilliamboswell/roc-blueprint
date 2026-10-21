## Inspectable build evidence. None of these records authorize execution.
import Spec
import Project
import Lock
import Sexpr

BuildModel := [].{
	Input : { name : Str, provider : Str, content_identity : Str }
	File : { path : Str, digest : Str }
	Node : { name : Str, dependencies : List(Str), declarations : Str, files : List(File), inputs : List(Input) }
	Snapshot : { name : Str, system : Str, provider : Str, nodes : List(Node) }
	Record : { schema_version : U64, snapshot : Snapshot, build_identity : Str, outputs : List({ name : Str, path : Str }) }
	Change : { build : Str, dependency_path : List(Str), kind : Str, name : Str }

	## The host supplies selected file measurements and adapter-selected source names.
	capture_node : Spec, Spec.Build, Str, List(File), List(Str), List(Lock.Source) -> Node
	capture_node = |spec, build, system, files, selected_sources, pins| {
		environment = spec.environments.keep_if(|entry| entry.name == build.environment)
		declarations = Sexpr.to_str({
			build,
			environment,
			system_tools: spec.system_tools.keep_if(|entry| entry.environment == build.environment and entry.system == system),
			commands: spec.commands.keep_if(|entry| entry.environment == build.environment),
			configured_tools: spec.configured_tools.keep_if(|entry| entry.environment == build.environment),
			roc_packages: spec.roc_packages.keep_if(|entry| entry.environment == build.environment),
			build_files: spec.build_files.keep_if(|entry| entry.build == build.name),
		})
		{
			name: build.name,
			dependencies: build.needs,
			declarations,
			files: files.sort_with(|a, b| Project.bytewise(a.path, b.path)),
			inputs: pins.keep_if(|source| selected_sources.contains(source.name)).map(|source| { name: source.name, provider: source.provider, content_identity: source.digest }).sort_with(|a, b| Project.bytewise(a.name, b.name)),
		}
	}

	digest : Snapshot -> Str
	digest = |snapshot| "sha256:${Crypto.SHA256.hash(Sexpr.to_str(snapshot).to_utf8()).to_hex()}"

	render_record : Record -> Try(Str, Str)
	render_record = |record| {
		validate(record)?
		text = Sexpr.to_str(record)
		if text.to_utf8().len() > 8388608 { return Err("build record exceeds 8 MiB") }
		Ok(text)
	}

	parse_record : Str -> Try(Record, Str)
	parse_record = |text| {
		if text.to_utf8().len() > 8388608 { return Err("build record exceeds 8 MiB") }
		record : Record
		record = Sexpr.parse(text).map_err(|_| "malformed build record")?
		validate(record)?
		Ok(record)
	}

	validate : Record -> Try({}, Str)
	validate = |record| {
		if record.schema_version != 1 { return Err("unsupported build record version") }
		if record.build_identity.is_empty() or record.snapshot.provider.is_empty() or record.outputs.is_empty() { return Err("incomplete build record") }
		if !record.snapshot.nodes.any(|node| node.name == record.snapshot.name) { return Err("build record is missing its selected build") }
		for node in record.snapshot.nodes {
			if !node.dependencies.all(|name| record.snapshot.nodes.any(|entry| entry.name == name)) { return Err("build record has incomplete dependencies") }
		}
		Ok({})
	}

	## Changes carry a path from the requested build, including shared dependencies.
	compare : Snapshot, Snapshot -> Try(List(Change), Str)
	compare = |before, after| {
		if before.name != after.name or before.system != after.system or before.provider != after.provider { return Err("baseline belongs to another build, system or provider") }
		var $changes = []
		for node in after.nodes {
			previous = before.nodes.find_first(|entry| entry.name == node.name)
			path = dependency_path(after, node.name, [after.name], after.nodes.len() + 1)
			change = |kind, name| { build: node.name, dependency_path: path, kind, name }
			match previous {
				Err(_) => { $changes = $changes.append(change("dependency-added", node.name)) }
				Ok(old) => {
					if old.declarations != node.declarations { $changes = $changes.append(change("declaration-changed", node.name)) }
					for file in node.files {
						if old.files.find_first(|entry| entry.path == file.path) != Ok(file) { $changes = $changes.append(change("file-changed", file.path)) }
					}
					for file in old.files {
						if !node.files.any(|entry| entry.path == file.path) { $changes = $changes.append(change("file-removed", file.path)) }
					}
					for input in node.inputs {
						if old.inputs.find_first(|entry| entry.name == input.name) != Ok(input) { $changes = $changes.append(change("input-changed", input.name)) }
					}
					for input in old.inputs {
						if !node.inputs.any(|entry| entry.name == input.name) { $changes = $changes.append(change("input-removed", input.name)) }
					}
				}
			}
		}
		for node in before.nodes {
			if !after.nodes.any(|entry| entry.name == node.name) { $changes = $changes.append({ build: node.name, dependency_path: [after.name, node.name], kind: "dependency-removed", name: node.name }) }
		}
		Ok($changes)
	}

	dependency_path : Snapshot, Str, List(Str), U64 -> List(Str)
	dependency_path = |snapshot, target, path, remaining| {
		current = path.last() ?? ""
		if current == target { return path }
		if remaining == 0 { return [] }
		match snapshot.nodes.find_first(|entry| entry.name == current) {
			Err(_) => []
			Ok(node) => {
				for dependency in node.dependencies {
					found = dependency_path(snapshot, target, path.append(dependency), remaining - 1)
					if !found.is_empty() { return found }
				}
				[]
			}
		}
	}
}

base : BuildModel.Snapshot
base = { name: "app", system: "linux", provider: "example", nodes: [
	{ name: "lib", dependencies: [], declarations: "compile", files: [{ path: "lib.c", digest: "a" }], inputs: [{ name: "compiler", provider: "example", content_identity: "v1" }] },
	{ name: "app", dependencies: ["lib"], declarations: "link", files: [], inputs: [] },
] }

expect BuildModel.compare(base, base) == Ok([])
expect {
	changed = { ..base, nodes: base.nodes.map(|node| if (node.name == "lib") { ..node, files: [{ path: "lib.c", digest: "b" }] } else node) }
	BuildModel.compare(base, changed) == Ok([{ build: "lib", dependency_path: ["app", "lib"], kind: "file-changed", name: "lib.c" }])
		and BuildModel.digest(base) != BuildModel.digest(changed)
}
expect {
	record = { schema_version: 1, snapshot: base, build_identity: "native:build", outputs: [{ name: "out", path: "/output" }] }
	(match BuildModel.render_record(record) { Ok(text) => BuildModel.parse_record(text)
		Err(message) => Err(message) }) == Ok(record)
		and BuildModel.parse_record("((schema_version 99))").is_err()
		and BuildModel.render_record({ ..record, build_identity: "" }).is_err()
}
