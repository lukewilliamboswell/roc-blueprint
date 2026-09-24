# Pure Nix rendering for validated, reusable environment closures.
import ir.Ir
import ir.Project
import ir.Value
import Backend

## Package names are native Nix attributes, never translated or filtered.
## Each environment imports its sources with only its ordered overlay stack.
## Shell aliases and task entries share those imports. Raw values remain data,
## not executable Nix; Custom extensions are deliberately unsupported.
## Raw supports Attrs at `flake` and `shell:<alias>`, ignores other backends,
## and rejects duplicate attributes or replacement of packages/devShells.
## Alias Raw does not leak into another alias or a task's environment entry.
NixBackend :: [].{
	backend : Backend
	backend = Backend.{
		name: "nix",
		features: ["raw"],
		render: |ir| render(ir).map_ok(
			|contents| [{ path: "flake.nix", contents }],
		),
		lock_file: "flake.lock",
		lock: |dir| ["nix", "flake", "lock", "path:${dir}"],
		update: |dir| ["nix", "flake", "update", "--flake", "path:${dir}"],
		enter_shell: |dir, shell| ["nix", "develop", "path:${dir}#${shell}"],
		run_in_shell: |dir, shell, command|
			["nix", "develop", "path:${dir}#${shell}", "-c"].concat(command),
	}

	default_nixpkgs : Str
	default_nixpkgs = "github:NixOS/nixpkgs/nixos-unstable"

	## Rendering supports these target shapes, not cross-compilation or a host
	## support claim. Nix itself rejects tools unavailable on a declared target.
	supported_systems : List(Str)
	supported_systems = [
		"x86_64-linux",
		"aarch64-linux",
		"x86_64-darwin",
		"aarch64-darwin",
	]

	## Reserved shell prefix keeps aliases distinct from task environment refs.
	environment_shell : Str -> Str
	environment_shell = |name| "blueprint-env-${name}"

	## Caller-owned staging; supplied lock bytes are trusted, not validated.
	## Local source rebasing and relocatable locks remain deferred to B2.
	render_files : Ir, Str, Backend.Layout, Backend.LockedInputs -> Try(List(Backend.File), Str)
	render_files = |ir, target, layout, locked_inputs| {
		if !ir.systems.contains(target) {
			return Err("target ${target} is not declared by the project")
		}
		for p in [
			layout.project_root,
			layout.workspace,
			layout.generated_root,
			layout.lock_path,
		] {
			if !p.starts_with("/") or p.to_utf8().contains(0)
				or p.split_on("/").contains("..") {
				return Err("layout paths must be absolute without NUL or traversal")
			}
		}
		for input in ir.inputs {
			if is_local(input.url) {
				return Err("render_files does not yet support local input ${input.name}")
			}
		}
		for source in ir.sources {
			url = match source.provider {
				Auto => ""
				NixPackages(ref) => ref
				GuixPackages(ref) => ref
			}
			if is_local(url) {
				return Err("render_files does not yet support local source ${source.name}")
			}
		}
		contents = render(ir)?
		Ok([
			{ path: "${layout.generated_root}/flake.nix", contents },
			{
				path: "${layout.generated_root}/flake.lock",
				contents: locked_inputs.contents,
			},
		])
	}

	is_local : Str -> Bool
	is_local = |url| url.starts_with("path:") or url.contains("file:")
		or url.starts_with("/") or url.starts_with(".")

	## Whole rendering checks only environments reachable from shells/tasks.
	## Whole-project structural validation still rejects malformed declarations.
	render : Ir -> Try(Str, Str)
	render = |ir| {
		project = Project.validate(ir)?
		names = project.shells.map(|s| s.environment)
			.concat(project.tasks.map(|t| t.environment))
		render_closure(project, names)
	}

	## A Shell/Run consumer selects one environment before staging any effects.
	## Unrelated provider constraints must not block this request.
	render_environment : Ir, Str -> Try(Str, Str)
	render_environment = |ir, name| {
		project = Project.validate(ir)?
		render_closure(project, [name])
	}

	render_closure : Ir, List(Str) -> Try(Str, Str)
	render_closure = |ir, names| {
		missing = ir.unsupported_features(backend.features)
		if !missing.is_empty() {
			return Err("unsupported features: ${Str.join_with(missing, ", ")}")
		}
		if !ir.extensions.is_empty() {
			kinds = ir.extensions.map(|e| "'${e.kind}' (${e.name})")
			return Err(
				"this blueprint does not support extensions yet; "
					.concat("Blueprint.roc uses ${Str.join_with(kinds, ", ")}"),
			)
		}
		for system in ir.systems {
			if !supported_systems.contains(system) {
				return Err("unsupported Nix target ${system}")
			}
		}
		for name in names {
			Project.check_environment(ir, Nix, name)?
		}
		environments = ir.environments.keep_if(|e| names.contains(e.name))
		shells = ir.shells.keep_if(|s| names.contains(s.environment))
		# Validate all Raw declarations, even aliases outside this request.
		# Only selected aliases are emitted; flake-level data is always retained.
		var $shell_raw = []
		var $flake_raw = []
		for r in ir.raw.keep_if(|r| r.backend == "nix") {
			if r.target == "flake" {
				$flake_raw = $flake_raw.concat(raw_attrs(r)?)
			} else if r.target.starts_with("shell:") {
				name = r.target.drop_prefix("shell:")
				if !ir.shells.any(|s| s.name == name) {
					return Err("raw nix target \"${r.target}\" names no shell")
				}
				$shell_raw = $shell_raw.concat(
					raw_attrs(r)?.map(|a| { shell: name, attr: a }),
				)
			} else {
				return Err(
					"unknown raw nix target \"${r.target}\"; "
						.concat("expected \"flake\" or \"shell:<name>\""),
				)
			}
		}
		check_attr_names(
			"the raw flake outputs",
			$flake_raw.map(|a| a.name),
			["devShells"],
		)?
		for shell in ir.shells {
			if shell.name.starts_with("blueprint-env-") {
				return Err("shell prefix blueprint-env- is reserved")
			}
			extra = $shell_raw.keep_if(|x| x.shell == shell.name)
				.map(|x| x.attr)
			check_attr_names(
				"the raw attributes of shell \"${shell.name}\"",
				extra.map(|a| a.name),
				["packages"],
			)?
		}
		# Keep source input identities independent of traversal order. Unused
		# sources are not needed to lock or evaluate the requested closure.
		sources = ir.sources.keep_if(
			|s| environments.any(|e| source_names(e).contains(s.name)),
		)
		var $input_lines = []
		for source in sources {
			url = match source.provider {
				Auto => default_nixpkgs
				NixPackages(ref) => ref
				GuixPackages(_) => return Err("Nix cannot use Guix source ${source.name}")
			}
			$input_lines = $input_lines.append(
				"    ${quote(source.name)}.url = ${quote(url)};",
			)
		}
		$input_lines = $input_lines.concat(
			ir.inputs.keep_if(|i| i.kind == Flake or environments.any(|e| e.overlays.contains(i.name)))
				.map(|i| "    ${quote(i.name)}.url = ${quote(i.url)};"),
		)
		env_lines = environments.map(render_environment_definition)
		entries = environments.map(
			|e| "          ${quote(environment_shell(e.name))} = "
				.concat("environments.${quote(e.name)} { };"),
		).concat(
			shells.map(
				|s| {
					extra = $shell_raw.keep_if(|x| x.shell == s.name).map(|x| x.attr)
					"          ${quote(s.name)} = environments.${quote(s.environment)} "
						.concat("${value_to_nix(Value.Attrs(extra))};")
				},
			),
		)
		systems = ir.systems.map(
			|system|
				lines([
					"        ${quote(system)} = let",
					"          environments = environmentsFor ${quote(system)};",
					"        in {",
				]).concat(lines(entries)).concat(lines(["        };"])),
		)
		flake_lines = $flake_raw.map(
			|a| "      ${quote(a.name)} = ${value_to_nix(a.value)};",
		)
		Ok(
			lines([
				"# Generated by blueprint from Blueprint.roc. Do not edit.",
				"{",
				"  description = ${quote("Development environments for ${ir.name}")};",
				"",
				"  inputs = {",
			]).concat(lines($input_lines)).concat(
				lines([
					"  };",
					"",
					"  outputs = { self, ... }@inputs:",
					"    let",
					"      environmentsFor = system: {",
				]),
			).concat(Str.join_with(env_lines, "")).concat(
				lines([
					"      };",
					"    in",
					"    {",
					"      devShells = {",
				]),
			).concat(Str.join_with(systems, "")).concat(lines(["      };"]))
				.concat(lines(flake_lines)).concat(lines(["    };", "}"])),
		)
	}

	## mkShell comes from the first tool's source, keeping unrelated providers
	## outside the request. Empty environments use the default source instead.
	source_names : Ir.Environment -> List(Str)
	source_names = |environment| {
		if environment.tools.is_empty() {
			return ["default"]
		}
		environment.tools.map(|t| t.source).fold(
			[],
			|seen, name|
				if seen.contains(name) seen else seen.append(name),
		)
	}

	render_environment_definition : Ir.Environment -> Str
	render_environment_definition = |environment| {
		sources = source_names(environment)
		primary = sources.first() ?? "default"
		overlays = environment.overlays.map(
			|name| "inputs.${quote(name)}.overlays.default",
		)
		set_lines = sources.map(
			|name|
				"            ${quote(name)} = import inputs.${quote(name)} "
					.concat("{ inherit system overlays; };"),
		)
		tools = environment.tools.map(
			|tool|
				"            sets.${quote(tool.source)}."
					.concat(attr_path(tool.name.split_on("."))),
		)
		lines([
			"        ${quote(environment.name)} = let",
			"          overlays = [ ${Str.join_with(overlays, " ")} ];",
			"          sets = {",
		]).concat(lines(set_lines)).concat(
			lines([
				"          };",
				"        in extra: sets.${quote(primary)}.mkShell ({",
				"          packages = [",
			]),
		).concat(lines(tools)).concat(
			lines([
				"          ];",
				"        } // extra);",
			]),
		)
	}

	raw_attrs : Ir.Raw -> Try(List({ name : Str, value : Value }), Str)
	raw_attrs = |r| match r.value {
		Attrs(attrs) => Ok(attrs)
		_ => Err("raw nix value for \"${r.target}\" must be Attrs")
	}

	check_attr_names : Str, List(Str), List(Str) -> Try({}, Str)
	check_attr_names = |what, names, reserved| {
		var $seen = []
		for name in names {
			if reserved.contains(name) {
				return Err("${what} set \"${name}\", which the Nix backend writes itself")
			}
			if $seen.contains(name) {
				return Err("${what} set \"${name}\" more than once")
			}
			$seen = $seen.append(name)
		}
		Ok({})
	}

	## Render data only; interpolation and quotes cannot inject expressions.
	value_to_nix : Value -> Str
	value_to_nix = |value| match value {
		Str(s) => quote(s)
		Int(n) => if n < 0 "(${n.to_str()})" else n.to_str()
		Bool(b) => if b "true" else "false"
		List([]) => "[ ]"
		List(items) => "[ ${Str.join_with(items.map(value_to_nix), " ")} ]"
		Attrs([]) => "{ }"
		Attrs(attrs) => {
			fields = attrs.map(|a| "${quote(a.name)} = ${value_to_nix(a.value)};")
			"{ ${Str.join_with(fields, " ")} }"
		}
	}

	attr_path : List(Str) -> Str
	attr_path = |path| Str.join_with(path.map(quote), ".")

	lines : List(Str) -> Str
	lines = |items| items.fold("", |acc, line| acc.concat(line).concat("\n"))

	quote : Str -> Str
	quote = |value| {
		escaped = value
			.replace_each("\\", "\\\\")
			.replace_each("\"", "\\\"")
			.replace_each("\${", "\\\${")
			.replace_each("\n", "\\n")
			.replace_each("\r", "\\r")
			.replace_each("\t", "\\t")
		"\"${escaped}\""
	}
}

import "tests/sample.ir.scm" as sample_wire : Str
import "tests/full.ir.scm" as full_wire : Str
import "tests/sample.golden.nix" as sample_golden : Str
import "tests/full.golden.nix" as full_golden : Str

# The simple fixture covers scoped overlays, dotted attributes and aliases.
expect Ir.parse(sample_wire).map_err(|_| "invalid fixture")
	.map_ok(NixBackend.render) == Ok(Ok(sample_golden))

# The full fixture covers multiple sources, task-only environments and Raw data.
expect Ir.parse(full_wire).map_err(|_| "invalid fixture")
	.map_ok(NixBackend.render) == Ok(Ok(full_golden))

# Quotes, interpolation and control characters stay literal data.
expect NixBackend.value_to_nix(Value.Str("a\"b\\c\${d}\n\r\t")) ==
	"\"a\\\"b\\\\c\\\${d}\\n\\r\\t\""

# Nested data and negative numbers remain valid Nix expressions.
expect NixBackend.value_to_nix(
	Value.List([
		Value.Int(1),
		Value.Int(-2),
		Value.Attrs([{ name: "a b", value: Value.List([Value.Bool(True)]) }]),
	]),
) == "[ 1 (-2) { \"a b\" = [ true ]; } ]"

# Empty aggregate data and booleans preserve their native Nix values.
expect [Value.List([]), Value.Attrs([]), Value.Bool(False)]
	.map(NixBackend.value_to_nix) == ["[ ]", "{ }", "false"]

# Ordinary dollars without interpolation need no escaping.
expect NixBackend.value_to_nix(Value.Str("$x \$ {y}")) == "\"$x \$ {y}\""

# Focused IR values exercise the public renderer without a CLI or effects.
TestIr : {
	systems : List(Str),
	sources : List(Ir.Source),
	inputs : List(Ir.Input),
	environments : List(Ir.Environment),
	shells : List(Ir.Shell),
	tasks : List(Ir.Task),
	requires_ : List(Str),
	raw : List(Ir.Raw),
	extensions : List(Ir.Extension),
}

base : Ir.Environment
base = { name: "dev", parents: [], tools: [], overlays: [] }

simple : TestIr
simple = {
	systems: ["x86_64-linux"],
	sources: [],
	inputs: [],
	environments: [base],
	shells: [{ name: "default", environment: "dev" }],
	tasks: [],
	requires_: [],
	raw: [],
	extensions: [],
}

mk : TestIr -> Ir
mk = |t| Ir.{
	format: Ir.current_format,
	name: "test",
	systems: t.systems,
	sources: t.sources,
	inputs: t.inputs,
	environments: t.environments,
	shells: t.shells,
	tasks: t.tasks,
	requires_: t.requires_,
	raw: t.raw,
	extensions: t.extensions,
}

rejects : TestIr, Str -> Bool
rejects = |t, fragment| match NixBackend.render(mk(t)) {
	Err(message) => message.contains(fragment)
	Ok(_) => False
}

foreign : Ir.Environment
foreign = {
	..base,
	name: "foreign",
	tools: [{ source: "guix", name: "python@3:out" }],
}

mixed : TestIr
mixed = {
	..simple,
	sources: [{ name: "guix", provider: GuixPackages("channels") }],
	environments: [base, foreign],
}

# An omitted package source supplies mkShell from the backend's default.
expect match NixBackend.render(mk(simple)) {
	Ok(text) => text.contains(
		"\"default\".url = \"github:NixOS/nixpkgs/nixos-unstable\";",
	)
	Err(_) => False
}

# Tasks need stable entries even when no alias refers to their environment.
expect match NixBackend.render(
	mk({
		..simple,
		shells: [],
		tasks: [{ name: "check", environment: "dev", run: ["git", "--version"] }],
	}),
) {
	Ok(text) => text.contains("\"blueprint-env-dev\" = environments.\"dev\"")
	Err(_) => False
}

# Unused Guix declarations must not block the project's Nix shell/task closure.
expect NixBackend.render(mk(mixed)).is_ok()

# Selecting the foreign environment fails instead of overriding its provider.
expect NixBackend.render_environment(mk(mixed), "foreign").is_err()

# A selected Nix environment works even when another shell needs Guix.
expect {
	project = mk({
		..mixed,
		shells: simple.shells.append({ name: "foreign", environment: "foreign" }),
	})
	NixBackend.render(project).is_err()
		and NixBackend.render_environment(project, "dev").is_ok()
}

# Inherited stacks stay ordered, deduplicated and scoped to the chosen env.
expect {
	parent = { ..base, name: "base", overlays: ["base"] }
	child = { ..base, parents: ["base"], overlays: ["base", "patch"] }
	stacked = {
		..simple,
		inputs: [
			{ name: "base", url: "github:example/base", kind: Overlay },
			{ name: "patch", url: "github:example/patch", kind: Overlay },
		],
		environments: [parent, child],
	}
	inherited = NixBackend.render_environment(mk(stacked), "dev")
	inline = NixBackend.render_environment(
		mk({
			..stacked,
			environments: [parent, { ..child, parents: [] }],
		}),
		"dev",
	)
	inherited == inline and match inherited {
		Ok(text) => text.contains(
			"overlays = [ inputs.\"base\".overlays.default "
				.concat("inputs.\"patch\".overlays.default ];"),
		)
		Err(_) => False
	} and match NixBackend.render_environment(mk(stacked), "base") {
		Ok(text) => !text.contains("inputs.\"patch\".overlays.default")
		Err(_) => False
	}
}

# Unknown requests fail before a caller can generate files or invoke Nix.
expect NixBackend.render_environment(mk(simple), "missing").is_err()

# All supported target shapes are explicit; unsupported declarations are errors.
expect NixBackend.render(
	mk({
		..simple,
		systems: NixBackend.supported_systems,
	}),
).is_ok() and rejects({ ..simple, systems: ["riscv64-linux"] }, "target")

# Native missing attributes survive rendering and fail later in Nix itself.
expect match NixBackend.render(
	mk({
		..simple,
		environments: [
			{
				..base,
				tools: [{ source: "default", name: "missingNativePackage" }],
			},
		],
	}),
) {
	Ok(text) => text.contains("sets.\"default\".\"missingNativePackage\"")
		and !text.contains("builtins.filter") and !text.contains("availableOn")
	Err(_) => False
}

# Auto tool syntax is checked for the selected provider before any effects.
expect NixBackend.render(
	mk({
		..simple,
		environments: [
			{
				..base,
				tools: [{ source: "default", name: "python@3:out" }],
			},
		],
	}),
).is_err()

# Native numeric-leading attributes are quoted, not rejected as identifiers.
expect match NixBackend.render(mk({ ..simple, environments: [{ ..base, tools: [{ source: "default", name: "7zip" }] }] })) {
	Ok(text) => text.contains("sets.\"default\".\"7zip\"")
	Err(_) => False
}

# Unknown capability requirements cannot disappear during direct rendering.
expect rejects({ ..simple, requires_: ["future-build"] }, "future-build")

# Unsupported Custom blocks retain the clear extension diagnostic.
expect rejects(
	{
		..simple,
		extensions: [{ kind: "service", name: "db", value: Value.Attrs([]) }],
	},
	"does not support extensions",
)

# Raw targeting another backend stays inert, regardless of its value shape.
expect NixBackend.render(
	mk({
		..simple,
		raw: [{ backend: "guix", target: "bogus", value: Value.Int(1) }],
	}),
).is_ok()

# Nix Raw targets must be either the flake or a declared shell alias.
expect rejects(
	{
		..simple,
		raw: [{ backend: "nix", target: "bogus", value: Value.Attrs([]) }],
	},
	"unknown raw nix target",
) and rejects(
	{
		..simple,
		raw: [{ backend: "nix", target: "shell:nope", value: Value.Attrs([]) }],
	},
	"names no shell",
)

# Shell Raw must be attribute data, not a string of Nix expressions.
expect rejects(
	{
		..simple,
		raw: [{ backend: "nix", target: "shell:default", value: Value.Str("x") }],
	},
	"must be Attrs",
)

# Raw cannot overwrite generated packages or flake devShells.
expect rejects(
	{
		..simple,
		raw: [
			{
				backend: "nix",
				target: "shell:default",
				value: Value.Attrs([
					{ name: "packages", value: Value.List([]) },
				]),
			},
		],
	},
	"set \"packages\"",
) and rejects(
	{
		..simple,
		raw: [
			{
				backend: "nix",
				target: "flake",
				value: Value.Attrs([
					{ name: "devShells", value: Value.Attrs([]) },
				]),
			},
		],
	},
	"set \"devShells\"",
)

# Duplicate Raw attributes across entries produce a diagnostic, not invalid Nix.
expect {
	raw = {
		backend: "nix",
		target: "shell:default",
		value: Value.Attrs([
			{ name: "FOO", value: Value.Str("bar") },
		]),
	}
	rejects({ ..simple, raw: [raw, raw] }, "more than once")
}

# Shell aliases cannot collide with stable task environment output names.
expect NixBackend.render(
	mk({
		..simple,
		shells: [{ name: "blueprint-env-dev", environment: "dev" }],
	}),
).is_err()
