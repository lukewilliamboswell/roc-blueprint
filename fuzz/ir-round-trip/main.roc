app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", ir: "../../ir/main.roc", roc: "nightly-2026-09-19-d025939" }

import fuzz.Fuzz
import ir.Ir

## Any IR the platform can build must survive `Ir.to_str` then `Ir.parse`
## unchanged, whatever characters its strings contain.
test : Ir -> Fuzz.Outcome
test = |ir|
	match Ir.parse(ir.to_str()) {
		Ok(parsed) if parsed == ir => Fuzz.keep
		Ok(_) => crash "IR round trip changed the value"
		Err(_) => crash "IR output could not be parsed"
	}

system : Fuzz.Generator(Ir.System)
system = Fuzz.map(
	Fuzz.u8_in(0, 3),
	|n|
		match n {
			0 => Aarch64Darwin
			1 => Aarch64Linux
			2 => X86_64Darwin
			_ => X86_64Linux
		},
)

shell : Fuzz.Generator(Ir.Shell)
shell = {
	name: Fuzz.str,
	tools: Fuzz.list(Fuzz.list(Fuzz.str, 4), 4),
}.Fuzz

task : Fuzz.Generator(Ir.Task)
task = {
	name: Fuzz.str,
	shell: Fuzz.str,
	run: Fuzz.list(Fuzz.str, 4),
}.Fuzz

ir_generator : Fuzz.Generator(Ir)
ir_generator = Fuzz.map(
	{
		name: Fuzz.str,
		systems: Fuzz.list(system, 4),
		overlays: Fuzz.list(Fuzz.str, 3),
		shells: Fuzz.list(shell, 3),
		tasks: Fuzz.list(task, 3),
	}.Fuzz,
	|r| Ir.{ version: Ir.current_version, name: r.name, systems: r.systems, overlays: r.overlays, shells: r.shells, tasks: r.tasks },
)

target = Fuzz.target_with({
	name: "ir-round-trip",
	generator: ir_generator,
	test,
	show: |ir| ir.to_str(),
})
