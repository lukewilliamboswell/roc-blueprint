# Generate Specs from declaration-like words and arbitrary text, and probe the Nix grammars.
app [target] {
	core: "../../main.roc",
	nix: "../../../blueprint-nix/main.roc",
	pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst",
}

import pf.Fuzz
import core.Project
import core.Spec
import core.Value
import nix.Native

## A Spec, and a string and an executor for the Nix grammars.
Case : { spec : Spec, probe : Str, executor : Spec.Executor }

## `Project.validate` must return a result for any Spec, never crash or hang,
## and is idempotent: what it returns as `Ok(validated)` validates to
## `Ok(validated)`. `Native.check_ref`, `check_tool(Nix, _)`,
## `check_tool(Guix, _)`, `nix_path` and `check_executor` must return a result
## for any string or executor.
test : Case -> Fuzz.Outcome
test = |case| {
	match Project.validate(case.spec) {
		Ok(validated) =>
			if Project.validate(validated) != Ok(validated) {
				crash "validation is not idempotent"
			}
		Err(_) => {}
	}
	strings = [case.probe]
		.concat(case.spec.sources.map(|source| source.provider.ref))
		.concat(case.spec.inputs.map(|input| input.url))
		.concat(case.spec.environments.fold([], |names, environment| names.concat(environment.tools.map(|tool| tool.name))))
	for text in strings {
		_ = Native.check_ref(text)
		_ = Native.check_tool(Nix, text)
		_ = Native.check_tool(Guix, text)
		_ = Native.nix_path(text)
	}
	for executor in case.spec.executors.append(case.executor) {
		_ = Native.check_executor(executor)
	}
	Fuzz.keep
}

## A word a declaration would use, or any text. The words let validation get
## past its first checks; the text finds what the words do not.
text : Fuzz.Generator(Str)
text = |state| {
	words = ["", "a", "b", "dev", "default", "nix", "x86_64-linux", "aarch64-darwin", "sources", "builds", "workflows", "programs", "path:assets", "github:NixOS/nixpkgs", "https://example.test/a.tar.gz", "python3", "zigpkgs.\"0.16.0\"", "git@2:out", "true", "out"]
	choice = Fuzz.u8_in(0, U64.to_u8_wrap(words.len() + 3))(state)
	match words.get(choice.value.to_u64()) {
		Ok(word) => Fuzz.constant(word)(choice.state)
		Err(_) => Fuzz.str(choice.state)
	}
}

# The generators below are those of spec-round-trip, drawing from `text`
# and with shorter lists, plus the ownership records it leaves empty.

## A `Value` nested at most `depth` levels deep.
value : U64 -> Fuzz.Generator(Value)
value = |depth| |state| {
	choice = Fuzz.u8_in(0, if (depth == 0) 2 else 4)(state)
	match choice.value {
		0 => Fuzz.map(text, |s| Value.Str(s))(choice.state)
		1 => Fuzz.map(Fuzz.u64, |n| Value.Int(U64.to_i64_wrap(n)))(choice.state)
		2 => Fuzz.map(Fuzz.u8_in(0, 1), |b| Value.Bool(b == 1))(choice.state)
		3 => Fuzz.map(
			Fuzz.list(value(depth - 1), 2),
			|items| Value.List(items),
		)(choice.state)
		_ => Fuzz.map(
			Fuzz.list({ name: text, value: value(depth - 1) }.Fuzz, 2),
			|attrs| Value.Attrs(attrs),
		)(choice.state)
	}
}

source : Fuzz.Generator(Spec.Source)
source = {
	name: text,
	provider: Fuzz.map(
		{ kind: Fuzz.u8_in(0, 2), ref: text }.Fuzz,
		|r|
			match r.kind {
				0 => { name: "fixture", version: 1, ref: r.ref }
				1 => { name: "nix", version: 1, ref: r.ref }
				_ => { name: "guix", version: 1, ref: r.ref }
			},
	),
}.Fuzz

input : Fuzz.Generator(Spec.Input)
input = {
	name: text,
	url: text,
}.Fuzz

tool : Fuzz.Generator(Spec.Tool)
tool = { source: text, name: text }.Fuzz

environment : Fuzz.Generator(Spec.Environment)
environment = {
	name: text,
	parents: Fuzz.list(text, 2),
	tools: Fuzz.list(tool, 2),
	overlays: Fuzz.list(text, 2),
}.Fuzz

shell : Fuzz.Generator(Spec.Shell)
shell = { name: text, environment: text }.Fuzz

task : Fuzz.Generator(Spec.Task)
task = {
	name: text,
	environment: text,
	run: Fuzz.list(text, 2),
}.Fuzz

build_source : Fuzz.Generator(Spec.BuildSource)
build_source = { name: text, ref: text }.Fuzz

build : Fuzz.Generator(Spec.Build)
build = {
	name: text,
	environment: text,
	inputs: Fuzz.list(text, 2),
	needs: Fuzz.list(text, 2),
	run: Fuzz.list(text, 2),
	output: text,
}.Fuzz

workflow_step : Fuzz.Generator(Spec.WorkflowStep)
workflow_step = Fuzz.map(
	{ kind: Fuzz.u8_in(0, 2), name: text, argv: Fuzz.list(text, 2) }.Fuzz,
	|r| match r.kind {
		0 => RunTask(r.name, r.argv)
		1 => BuildArtifact(r.name)
		_ => RunWorkflow(r.name)
	},
)

workflow : Fuzz.Generator(Spec.Workflow)
workflow = { name: text, steps: Fuzz.list(workflow_step, 3) }.Fuzz

extension : Fuzz.Generator(Spec.Extension)
extension = {
	kind: text,
	name: text,
	value: value(2),
}.Fuzz

raw : Fuzz.Generator(Spec.Raw)
raw = {
	backend: text,
	target: text,
	value: value(2),
}.Fuzz

program : Fuzz.Generator(Spec.Program)
program = Fuzz.map(
	{ kind: Fuzz.u8_in(0, 3), name: text, system: text, urls: Fuzz.list(text, 2), path: text }.Fuzz,
	|r| {
		name: r.name,
		system: r.system,
		urls: r.urls,
		unpack: match r.kind {
			0 => File
			1 => TarGz
			2 => TarXz
			_ => Zip
		},
		path: r.path,
	},
)

executor : Fuzz.Generator(Spec.Executor)
executor = { name: text, provider: text, source: text }.Fuzz

spec_generator : Fuzz.Generator(Spec)
spec_generator = Fuzz.map(
	{
		resolvers: Fuzz.list({ provider: text, inputs: Fuzz.list(text, 2) }.Fuzz, 2),
		executors: Fuzz.list(executor, 2),
		build_executors: Fuzz.list({ build: text, executor: text }.Fuzz, 2),
		source_files: Fuzz.list({ name: text, url: text, sha256: text }.Fuzz, 1),
		build_files: Fuzz.list({ build: text, paths: Fuzz.list(text, 2) }.Fuzz, 1),
		minor: Fuzz.u64,
		name: text,
		requires_: Fuzz.list(text, 3),
		systems: Fuzz.list(text, 2),
		sources: Fuzz.list(source, 2),
		inputs: Fuzz.list(input, 2),
		environments: Fuzz.list(environment, 3),
		system_tools: Fuzz.list({ environment: text, system: text, tools: Fuzz.list(tool, 2) }.Fuzz, 2),
		commands: Fuzz.list({ environment: text, name: text, tool }.Fuzz, 2),
		configured_tools: Fuzz.list({ environment: text, tool, options: value(2) }.Fuzz, 2),
		roc_packages: Fuzz.list({ environment: text, name: text, source: text }.Fuzz, 2),
		programs: Fuzz.list(program, 2),
		environment_programs: Fuzz.list({ environment: text, programs: Fuzz.list(text, 2) }.Fuzz, 2),
		expects: Fuzz.list({ environment: text, programs: Fuzz.list(text, 2) }.Fuzz, 2),
		shells: Fuzz.list(shell, 2),
		tasks: Fuzz.list(task, 2),
		build_sources: Fuzz.list(build_source, 2),
		builds: Fuzz.list(build, 3),
		workflows: Fuzz.list(workflow, 3),
		extensions: Fuzz.list(extension, 2),
		raw: Fuzz.list(raw, 2),
	}.Fuzz,
	|r| Spec.{
		resolvers: r.resolvers,
		executors: r.executors,
		build_executors: r.build_executors,
		source_files: r.source_files,
		build_files: r.build_files,
		format: { major: Spec.current_format.major, minor: r.minor },
		name: r.name,
		requires_: r.requires_,
		systems: r.systems,
		sources: r.sources,
		inputs: r.inputs,
		environments: r.environments,
		system_tools: r.system_tools,
		commands: r.commands,
		configured_tools: r.configured_tools,
		roc_packages: r.roc_packages,
		programs: r.programs,
		environment_programs: r.environment_programs,
		expects: r.expects,
		shells: r.shells,
		tasks: r.tasks,
		build_sources: r.build_sources,
		builds: r.builds,
		workflows: r.workflows,
		extensions: r.extensions,
		raw: r.raw,
	},
)

case_generator : Fuzz.Generator(Case)
case_generator = { spec: spec_generator, probe: Fuzz.str, executor }.Fuzz

target = Fuzz.target_with({
	name: "project-validate",
	generator: case_generator,
	test,
	show: |case| "${case.spec.to_str()}\nprobe: ${Str.inspect(case.probe)}\nexecutor: ${Str.inspect(case.executor)}",
})
