app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", ir: "../../main.roc", roc: "nightly-2026-09-19-d025939" }

import fuzz.Fuzz
import ir.Ir
import ir.Value

## Any IR the platform can build must survive `Ir.to_str` then `Ir.parse`
## unchanged, whatever characters its strings contain.
test : Ir -> Fuzz.Outcome
test = |ir|
	match Ir.parse(ir.to_str()) {
		Ok(parsed) if parsed == ir => Fuzz.keep
		Ok(_) => crash "IR round trip changed the value"
		Err(_) => crash "IR output could not be parsed"
	}

## A `Value` nested at most `depth` levels deep.
value : U64 -> Fuzz.Generator(Value)
value = |depth| |state| {
	choice = Fuzz.u8_in(0, if depth == 0 2 else 4)(state)
	match choice.value {
		0 => Fuzz.map(Fuzz.str, |s| Value.Str(s))(choice.state)
		1 => Fuzz.map(Fuzz.u64, |n| Value.Int(U64.to_i64_wrap(n)))(choice.state)
		2 => Fuzz.map(Fuzz.u8_in(0, 1), |b| Value.Bool(b == 1))(choice.state)
		3 => Fuzz.map(Fuzz.list(value(depth - 1), 3), |items| Value.List(items))(choice.state)
		_ => Fuzz.map(Fuzz.list({ name: Fuzz.str, value: value(depth - 1) }.Fuzz, 3), |attrs| Value.Attrs(attrs))(choice.state)
	}
}

input : Fuzz.Generator(Ir.Input)
input = {
	name: Fuzz.str,
	url: Fuzz.str,
	kind: Fuzz.map(
		Fuzz.u8_in(0, 2),
		|n|
			match n {
				0 => Packages
				1 => Overlay
				_ => Flake
			},
	),
}.Fuzz

package_gen : Fuzz.Generator(Ir.Package)
package_gen = {
	source: Fuzz.str,
	path: Fuzz.list(Fuzz.str, 4),
}.Fuzz

shell : Fuzz.Generator(Ir.Shell)
shell = {
	name: Fuzz.str,
	packages_: Fuzz.list(package_gen, 4),
}.Fuzz

task : Fuzz.Generator(Ir.Task)
task = {
	name: Fuzz.str,
	shell: Fuzz.str,
	run: Fuzz.list(Fuzz.str, 4),
}.Fuzz

extension : Fuzz.Generator(Ir.Extension)
extension = {
	kind: Fuzz.str,
	name: Fuzz.str,
	value: value(4),
}.Fuzz

raw : Fuzz.Generator(Ir.Raw)
raw = {
	backend: Fuzz.str,
	target: Fuzz.str,
	value: value(4),
}.Fuzz

ir_generator : Fuzz.Generator(Ir)
ir_generator = Fuzz.map(
	{
		minor: Fuzz.u64,
		name: Fuzz.str,
		requires_: Fuzz.list(Fuzz.str, 3),
		systems: Fuzz.list(Fuzz.str, 4),
		inputs: Fuzz.list(input, 3),
		shells: Fuzz.list(shell, 3),
		tasks: Fuzz.list(task, 3),
		extensions: Fuzz.list(extension, 3),
		raw: Fuzz.list(raw, 3),
	}.Fuzz,
	|r| Ir.{
		format: { major: Ir.current_format.major, minor: r.minor },
		name: r.name,
		requires_: r.requires_,
		systems: r.systems,
		inputs: r.inputs,
		shells: r.shells,
		tasks: r.tasks,
		extensions: r.extensions,
		raw: r.raw,
	},
)

target = Fuzz.target_with({
	name: "ir-round-trip",
	generator: ir_generator,
	test,
	show: |ir| ir.to_str(),
})
