# Generate major-2 wire records, including arbitrary provider and graph data.
app [target] {
	pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst",
	core: "../../main.roc",
}

import pf.Fuzz
import core.Spec
import core.Value

## Any Spec the platform can build must survive `Spec.to_str` then `Spec.parse`
## unchanged, whatever characters its strings contain.
test : Spec -> Fuzz.Outcome
test = |spec|
	match Spec.parse(spec.to_str()) {
		Ok(parsed) if parsed == spec => Fuzz.keep
		Ok(_) => crash "Spec round trip changed the value"
		Err(_) => crash "Spec output could not be parsed"
	}

## A `Value` nested at most `depth` levels deep.
value : U64 -> Fuzz.Generator(Value)
value = |depth| |state| {
	choice = Fuzz.u8_in(0, if depth == 0 2 else 4)(state)
	match choice.value {
		0 => Fuzz.map(Fuzz.str, |s| Value.Str(s))(choice.state)
		1 => Fuzz.map(Fuzz.u64, |n| Value.Int(U64.to_i64_wrap(n)))(choice.state)
		2 => Fuzz.map(Fuzz.u8_in(0, 1), |b| Value.Bool(b == 1))(choice.state)
		3 => Fuzz.map(
			Fuzz.list(value(depth - 1), 3),
			|items| Value.List(items),
		)(choice.state)
		_ => Fuzz.map(
			Fuzz.list({ name: Fuzz.str, value: value(depth - 1) }.Fuzz, 3),
			|attrs| Value.Attrs(attrs),
		)(choice.state)
	}
}

source : Fuzz.Generator(Spec.Source)
source = {
	name: Fuzz.str,
	provider: Fuzz.map(
		{ kind: Fuzz.u8_in(0, 2), ref: Fuzz.str }.Fuzz,
		|r|
			match r.kind {
				0 => Auto
				1 => NixPackages(r.ref)
				_ => GuixPackages(r.ref)
			},
	),
}.Fuzz

input : Fuzz.Generator(Spec.Input)
input = {
	name: Fuzz.str,
	url: Fuzz.str,
	kind: Fuzz.map(
		Fuzz.u8_in(0, 1),
		|n| if n == 0 Overlay else Flake,
	),
}.Fuzz

tool : Fuzz.Generator(Spec.Tool)
tool = { source: Fuzz.str, name: Fuzz.str }.Fuzz

environment : Fuzz.Generator(Spec.Environment)
environment = {
	name: Fuzz.str,
	parents: Fuzz.list(Fuzz.str, 3),
	tools: Fuzz.list(tool, 4),
	overlays: Fuzz.list(Fuzz.str, 3),
}.Fuzz

shell : Fuzz.Generator(Spec.Shell)
shell = { name: Fuzz.str, environment: Fuzz.str }.Fuzz

task : Fuzz.Generator(Spec.Task)
task = {
	name: Fuzz.str,
	environment: Fuzz.str,
	run: Fuzz.list(Fuzz.str, 4),
}.Fuzz

# B2 adds optional records; arbitrary strings/graphs must still round-trip.
build_source : Fuzz.Generator(Spec.BuildSource)
build_source = { name: Fuzz.str, ref: Fuzz.str }.Fuzz

build : Fuzz.Generator(Spec.Build)
build = {
	name: Fuzz.str,
	environment: Fuzz.str,
	inputs: Fuzz.list(Fuzz.str, 3),
	needs: Fuzz.list(Fuzz.str, 3),
	run: Fuzz.list(Fuzz.str, 4),
	output: Fuzz.str,
}.Fuzz

# Exercise every workflow tag with arbitrary literal argument bytes.
workflow_step : Fuzz.Generator(Spec.WorkflowStep)
workflow_step = Fuzz.map(
	{ kind: Fuzz.u8_in(0, 2), name: Fuzz.str, argv: Fuzz.list(Fuzz.str, 4) }.Fuzz,
	|r| match r.kind {
		0 => RunTask(r.name, r.argv)
		1 => BuildArtifact(r.name)
		_ => RunWorkflow(r.name)
	},
)

workflow : Fuzz.Generator(Spec.Workflow)
workflow = { name: Fuzz.str, steps: Fuzz.list(workflow_step, 4) }.Fuzz

extension : Fuzz.Generator(Spec.Extension)
extension = {
	kind: Fuzz.str,
	name: Fuzz.str,
	value: value(4),
}.Fuzz

raw : Fuzz.Generator(Spec.Raw)
raw = {
	backend: Fuzz.str,
	target: Fuzz.str,
	value: value(4),
}.Fuzz

spec_generator : Fuzz.Generator(Spec)
spec_generator = Fuzz.map(
	{
		minor: Fuzz.u64,
		name: Fuzz.str,
		requires_: Fuzz.list(Fuzz.str, 3),
		systems: Fuzz.list(Fuzz.str, 4),
		sources: Fuzz.list(source, 3),
		inputs: Fuzz.list(input, 3),
		environments: Fuzz.list(environment, 3),
		shells: Fuzz.list(shell, 3),
		tasks: Fuzz.list(task, 3),
		build_sources: Fuzz.list(build_source, 3),
		builds: Fuzz.list(build, 3),
		workflows: Fuzz.list(workflow, 3),
		extensions: Fuzz.list(extension, 3),
		raw: Fuzz.list(raw, 3),
	}.Fuzz,
	|r| Spec.{
		format: { major: Spec.current_format.major, minor: r.minor },
		name: r.name,
		requires_: r.requires_,
		systems: r.systems,
		sources: r.sources,
		inputs: r.inputs,
		environments: r.environments,
		shells: r.shells,
		tasks: r.tasks,
		build_sources: r.build_sources,
		builds: r.builds,
		workflows: r.workflows,
		extensions: r.extensions,
		raw: r.raw,
	},
)

target = Fuzz.target_with({
	name: "spec-round-trip",
	generator: spec_generator,
	test,
	show: |spec| spec.to_str(),
})
