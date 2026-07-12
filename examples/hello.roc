app [main!] {
	pf: platform "https://github.com/lukewilliamboswell/roc-platform-template-zig/releases/download/1.0.0/AnZoxzoGPtSGQ15EQh6pBeeaHJ7aizP9MQhK81dES3Uq.tar.zst",
	blueprint: "../packages/blueprint/main.roc",
	blueprint_nix: "../packages/blueprint-nix/main.roc",
}

import pf.Stdout
import blueprint.Plan
import blueprint_nix.BlueprintNix

main! : List(Str) => Try({}, [Exit(I32), StdoutErr(Str), ..])
main! = |_args| {
	plan : Plan
	plan = { field1: "hello from roc-blueprint", field2: 42 }

	Stdout.line!(BlueprintNix.render(plan))?
	Ok({})
}
