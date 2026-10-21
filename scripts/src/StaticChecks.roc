

## Checks of the repository's own text that need no compiler and no Nix. Each
## returns what is wrong, or "" when nothing is.
StaticChecks := [].{

	## The Roc source directories `roc fmt --check` covers.
	formatted = ["blueprint-core", "blueprint-platform", "blueprint-nix", "blueprint-cli", "fixtures", "examples"]

	## The directories `roc-stable fmt --check` covers instead. `roc fmt`
	## rewrites a header's `roc` field to the nightly that runs it, so the
	## scripts are formatted by the compiler their headers name.
	formatted_stable = ["scripts"]

	## Object files, archives and import libraries are fetched by content from
	## the release in `link-inputs.lock.json`; none may be committed.
	binary_patterns = ["*.o", "*.a", "*.lib"]

	tracked_binaries_problem : Str -> Str
	tracked_binaries_problem = |listed| {
		tracked = listed.split_on("\n").keep_if(|line| !line.is_empty())
		if (tracked.is_empty()) "" else "object files, archives and import libraries must not be committed:\n${Str.join_with(tracked, "\n")}"
	}

	## docs/architecture.adoc invariant 7: the CLI reaches a provider through
	## the Provider contract alone. Its source imports one module of the
	## provider, names it once, where the providers are listed, and never
	## runs a provider's tool itself.
	provider_contract_problem : Str -> Str
	provider_contract_problem = |cli_source| {
		imported = cli_source.split_on("\n").keep_if(|line| line.starts_with("import nix."))
		references = provider_references(cli_source)
		if imported != ["import nix.NixProvider"] or references != ["NixProvider"] {
			"blueprint-cli/main.roc must use only provider.* (found: ${Str.join_with(imported, ", ")} / ${Str.join_with(references, ", ")})"
		} else if cli_source.contains("\"nix\"") {
			"blueprint-cli/main.roc must not run provider tools itself"
		} else {
			""
		}
	}

	## Report projections and their JSON helper share the pure provider boundary.
	## None may import a platform through which it could evaluate or mutate.
	lock_inspector_contract_problem : Str -> Str
	lock_inspector_contract_problem = |source| {
		import_lines = source.split_on("\n").keep_if(|line| line.starts_with("import "))
		if import_lines.any(|line| !line.starts_with("import core.") and line != "import ReportJson") or !provider_references(source).is_empty() {
			"report modules must use only pure Core and ReportJson interfaces"
		} else ""
	}

	## Exported report codecs stay in the pure core package; no adapter or IO.
	core_report_contract_problem : Str -> Str
	core_report_contract_problem = |source| {
		allowed = ["import Lock", "import Provider", "import Value", "import JsonData", "import Project", "import Spec", "import Sexpr", "import Tree"]
		if source.split_on("\n").any(|line| line.starts_with("import ") and !allowed.contains(line)) {
			"core report modules must use only pure protocol modules"
		} else ""
	}

	## Every use of a member of a provider module: the identifier `Locks`, or
	## one starting `Nix` and made of letters, followed by a dot.
	provider_references : Str -> List(Str)
	provider_references = |source| {
		bytes = source.to_utf8()
		var $found = []
		var $start = 0
		var $index = 0
		while $index <= bytes.len() {
			byte = bytes.get($index) ?? 0
			if !word_byte(byte) {
				name = Str.from_utf8_lossy(bytes.sublist({ start: $start, len: $index - $start }))
				if byte == '.' and provider_module(name) {
					$found = $found.append(name)
				}
				$start = $index + 1
			}
			$index = $index + 1
		}
		$found
	}

	## The Systems `blueprint` runs on (`supported_host` in the CLI).
	host_systems = ["x86_64-linux", "aarch64-linux", "aarch64-darwin", "x86_64-windows"]

	## With no compatible compiler at hand, the CLI downloads the nightly it
	## evaluates with by a digest it records itself. There must be an entry
	## for that nightly on every System it runs on.
	bootstrap_problem : Str, Str -> Str
	bootstrap_problem = |compiler_version, bootstrap_source| {
		tag = compiler_version.trim()
		missing = host_systems.keep_if(|system| !bootstrap_source.contains("\t\t\ttag: \"${tag}\",\n\t\t\tsystem: \"${system}\",\n"))
		if (missing.is_empty()) "" else "record the download of the ${tag} compiler for ${Str.join_with(missing, ", ")} in compilers in blueprint-cli/Bootstrap.roc"
	}

	## The scripts run on `roc-stable`, which the flake names as `rocStableTag`.
	## Each script it runs says so twice: its first line starts it under that
	## command, and its header's `roc` field names that same nightly, so
	## another compiler refuses it. Nothing else selects a compiler: not a
	## `.roc-version`, which the product's `blueprint-cli/compiler-version`
	## replaced, and not a `roc` field in the platform, a package, an example
	## or a fixture, which follow the product compiler. `tracked` is what git
	## lists for `.roc-version`, `stable` the flake's tag, `pins` what git
	## grep prints for the `roc` fields of every Roc file, `shebangs` each
	## script with its first line.
	compilers_problem : Str, Try(Str, [NoConstant]), Str, List((Str, Str)) -> Str
	compilers_problem = |tracked, stable, pins, shebangs| {
		others = shebangs.keep_if(|(_, line)| line != script_shebang).map(|(script, _)| script)
		found = header_pins(pins)
		pinned = shebangs.map(|(script, _)| script).keep_if(|script| !product_built.contains(script))
		stray = found.keep_if(|(file, _)| !pinned.contains(file)).map(|(file, _)| file)
		if !tracked.trim().is_empty() {
			".roc-version must not exist: the product compiler is named in blueprint-cli/compiler-version, the scripts' in flake.nix"
		} else if !stray.is_empty() {
			"only a script roc-stable runs may pin a compiler with a roc field: ${Str.join_with(stray, " ")}"
		} else if !others.is_empty() {
			"scripts must start with ${script_shebang}: ${Str.join_with(others, " ")}"
		} else {
			match stable {
				Err(NoConstant) => "flake.nix does not name rocStableTag"
				Ok(tag) => {
					wrong = pinned.keep_if(|script| found.keep_if(|(file, _)| file == script).map(|(_, pin)| pin) != [tag])
					if (wrong.is_empty()) "" else "scripts must pin rocStableTag in their header, as roc: \"${tag}\": ${Str.join_with(wrong, " ")}"
				}
			}
		}
	}

	script_shebang = "#!/usr/bin/env roc-stable"

	## The scripts the product compiler builds: the smoke program released
	## beside each binary, and the tool the stubbed suites stand in for Nix
	## with. A header that named `roc-stable`'s nightly would stop them the day
	## the two compilers differ, so they name none.
	product_built = ["scripts/smoke_binary.roc", "scripts/stubs/tool.roc"]

	## Each file and nightly in what `git grep` prints for `roc` header
	## fields: lines of `<file>:<indent>roc: "<tag>",`.
	header_pins : Str -> List((Str, Str))
	header_pins = |listed|
		listed.split_on("\n").keep_if(|line| !line.is_empty()).map(
			|line| {
				file = line.split_on(":").first() ?? ""
				pin = line.split_on("roc: \"").get(1).map_ok(|rest| rest.split_on("\"").first() ?? "") ?? ""
				(file, pin)
			},
		)

	## fuzz.yml runs one job for each fuzz target, named in its matrix. A
	## target missing there would be replayed on every commit and never
	## fuzzed. `fuzzers` are the directories of `blueprint-core/fuzz` that
	## hold a `main.roc`.
	fuzz_matrix_problem : Str, List(Str) -> Str
	fuzz_matrix_problem = |workflow, fuzzers| {
		prefix = "target: ["
		listed = match workflow.split_on("\n").map(|line| line.trim()).find_first(|line| line.starts_with(prefix)) {
			Ok(line) => (line.drop_prefix(prefix).split_on("]").first() ?? "").split_on(",").map(|name| name.trim()).keep_if(|name| !name.is_empty())
			Err(_) => []
		}
		missing = fuzzers.keep_if(|name| !listed.contains(name))
		extra = listed.keep_if(|name| !fuzzers.contains(name))
		if missing.is_empty() and extra.is_empty() {
			""
		} else {
			"the target matrix of .github/workflows/fuzz.yml must list the fuzz targets (missing: ${Str.join_with(missing, " ")}; not a target: ${Str.join_with(extra, " ")})"
		}
	}

	## A workflow's token can do nothing unless a job says otherwise, and no
	## checkout leaves that token in the repository's git configuration.
	workflow_problem : Str, Str -> Str
	workflow_problem = |name, text| {
		lines = text.split_on("\n")
		checkouts = lines.keep_if(|line| line.contains("uses: actions/checkout@"))
		without_token = lines.keep_if(|line| line.trim() == "persist-credentials: false")
		if !lines.contains("permissions: {}") {
			"${name} must set top-level permissions: {} and state permissions per job"
		} else if checkouts.len() != without_token.len() {
			"${name}: every actions/checkout step must set persist-credentials: false"
		} else {
			""
		}
	}

	## The string a source file binds a name to, as in `name = "value"`.
	constant : Str, Str -> Try(Str, [NoConstant])
	constant = |source, name| {
		prefix = "${name} = \""
		match source.split_on("\n").map(|line| line.trim()).find_first(|line| line.starts_with(prefix)) {
			Ok(line) => Ok(line.drop_prefix(prefix).split_on("\"").first() ?? "")
			Err(_) => Err(NoConstant)
		}
	}

	## The core package's modules are listed where the flake copies them into
	## the CLI's source. That list must be the directory: a module missing from
	## it breaks only the Nix build.
	core_modules_problem : List(Str), List(Str) -> Str
	core_modules_problem = |in_directory, in_flake| {
		unlisted = in_directory.keep_if(|name| !in_flake.contains(name))
		absent = in_flake.keep_if(|name| !in_directory.contains(name))
		if unlisted.is_empty() and absent.is_empty() {
			""
		} else {
			"flake.nix must list exactly the modules of blueprint-core (not listed: ${Str.join_with(unlisted, " ")}; listed but absent: ${Str.join_with(absent, " ")})"
		}
	}

	## The Nix package and the CLI report one version.
	version_problem : Str, Str -> Str
	version_problem = |flake, cli_source|
		match (constant(flake, "version"), constant(cli_source, "version")) {
			(Ok(packaged), Ok(reported)) => if (packaged == reported) "" else "flake.nix packages version ${packaged}, but blueprint-cli/main.roc reports ${reported}"
			_ => "flake.nix and blueprint-cli/main.roc must each set version"
		}
}

word_byte : U8 -> Bool
word_byte = |byte| letter(byte) or (byte >= '0' and byte <= '9') or byte == '_'

letter : U8 -> Bool
letter = |byte| (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z')

provider_module : Str -> Bool
provider_module = |name| name == "Locks" or (name.starts_with("Nix") and name.to_utf8().all(letter))

cli_sample =
	\\import core.Provider
	\\import nix.NixProvider
	\\
	\\providers : List(Provider)
	\\providers = [NixProvider.provider]
	\\
	\\main! = |_| Realise.plan("nix develop", providers)
	\\

workflow_sample =
	\\permissions: {}
	\\
	\\jobs:
	\\  build:
	\\    permissions:
	\\      contents: read
	\\    steps:
	\\      - uses: actions/checkout@3d3c42e5 # v7.0.1
	\\        with:
	\\          persist-credentials: false
	\\

expect StaticChecks.tracked_binaries_problem("") == "" and StaticChecks.tracked_binaries_problem("\n") == ""
expect StaticChecks.tracked_binaries_problem("targets/x64musl/libc.a\ntargets/x64musl/crt1.o\n") == "object files, archives and import libraries must not be committed:\ntargets/x64musl/libc.a\ntargets/x64musl/crt1.o"

expect StaticChecks.provider_contract_problem(cli_sample) == ""
expect StaticChecks.provider_references(cli_sample) == ["NixProvider"]

# A second use of the provider module, or any use of its internals, is refused.
expect StaticChecks.provider_contract_problem("${cli_sample}other = NixProvider.render\n") == "blueprint-cli/main.roc must use only provider.* (found: import nix.NixProvider / NixProvider, NixProvider)"
expect StaticChecks.provider_contract_problem("${cli_sample}import nix.Locks\n") != ""
expect StaticChecks.provider_contract_problem("${cli_sample}decoded = Locks.decode(text)\n") != ""
expect StaticChecks.provider_contract_problem(cli_sample.replace_each("import nix.NixProvider\n", "")) != ""
expect StaticChecks.provider_contract_problem(cli_sample.replace_each("NixProvider.provider", "provider_from_elsewhere")) != ""
expect StaticChecks.provider_contract_problem("${cli_sample}run = Cmd.new(\"nix\")\n") == "blueprint-cli/main.roc must not run provider tools itself"

# Only an identifier of its own followed by a dot is a reference.
expect StaticChecks.provider_references("x = MyNixProvider.y\nz = NixProvider\nw = Nix2.v\nu = unLocks.t\n") == []
expect StaticChecks.provider_references("a = Locks.decode\nb = NixProvider.plan(Nix.x)\nc = HostProvider.plan\nd = Host.x") == ["Locks", "NixProvider", "Nix"]
expect StaticChecks.provider_references("Locks.") == ["Locks"]

expect StaticChecks.bootstrap_problem("nightly-1\n", StaticChecks.host_systems.map(|system| "\t\t\ttag: \"nightly-1\",\n\t\t\tsystem: \"${system}\",\n").fold("", Str.concat)) == ""
expect StaticChecks.bootstrap_problem("nightly-2\n", "\t\t\ttag: \"nightly-1\",\n\t\t\tsystem: \"x86_64-linux\",\n\t\t\ttag: \"nightly-2\",\n\t\t\tsystem: \"x86_64-linux\",\n") == "record the download of the nightly-2 compiler for aarch64-linux, aarch64-darwin, x86_64-windows in compilers in blueprint-cli/Bootstrap.roc"

pin_sample = "scripts/test.roc:\troc: \"nightly-1\",\n"

expect StaticChecks.header_pins("${pin_sample}examples/a/main.roc:    roc: \"0.1.0\" }\n") == [("scripts/test.roc", "nightly-1"), ("examples/a/main.roc", "0.1.0")]
expect StaticChecks.header_pins("") == []

expect StaticChecks.compilers_problem("", Ok("nightly-1"), pin_sample, [("scripts/test.roc", "#!/usr/bin/env roc-stable")]) == ""
expect StaticChecks.compilers_problem(".roc-version\n", Ok("nightly-1"), "", []) != ""
expect StaticChecks.compilers_problem("", Err(NoConstant), pin_sample, [("scripts/test.roc", "#!/usr/bin/env roc-stable")]) == "flake.nix does not name rocStableTag"
# A script without the pin, with another nightly's or with two.
expect StaticChecks.compilers_problem("", Ok("nightly-1"), "", [("scripts/test.roc", "#!/usr/bin/env roc-stable")]) == "scripts must pin rocStableTag in their header, as roc: \"nightly-1\": scripts/test.roc"
expect StaticChecks.compilers_problem("", Ok("nightly-2"), pin_sample, [("scripts/test.roc", "#!/usr/bin/env roc-stable")]) != ""
expect StaticChecks.compilers_problem("", Ok("nightly-1"), "${pin_sample}${pin_sample}", [("scripts/test.roc", "#!/usr/bin/env roc-stable")]) != ""
# The product compiler builds the smoke program, so it pins nothing.
expect StaticChecks.compilers_problem("", Ok("nightly-1"), "", [("scripts/smoke_binary.roc", "#!/usr/bin/env roc-stable")]) == ""
expect StaticChecks.compilers_problem("", Ok("nightly-1"), "scripts/smoke_binary.roc:\troc: \"nightly-1\",\n", [("scripts/smoke_binary.roc", "#!/usr/bin/env roc-stable")]) == "only a script roc-stable runs may pin a compiler with a roc field: scripts/smoke_binary.roc"
expect StaticChecks.compilers_problem("", Ok("nightly-1"), "examples/a/main.roc:\troc: \"nightly-1\",\n", []) == "only a script roc-stable runs may pin a compiler with a roc field: examples/a/main.roc"
expect StaticChecks.compilers_problem("", Ok("nightly-1"), "", [("scripts/smoke_binary.roc", "#!/usr/bin/env roc-stable"), ("scripts/b.roc", "#!/usr/bin/env roc"), ("scripts/c.roc", "app [main!] {")]) == "scripts must start with #!/usr/bin/env roc-stable: scripts/b.roc scripts/c.roc"

expect StaticChecks.fuzz_matrix_problem("      matrix:\n        target: [lock-parse, spec-parse]\n", ["spec-parse", "lock-parse"]) == ""
expect StaticChecks.fuzz_matrix_problem("        target: [lock-parse]\n", ["lock-parse", "spec-parse"]) == "the target matrix of .github/workflows/fuzz.yml must list the fuzz targets (missing: spec-parse; not a target: )"
expect StaticChecks.fuzz_matrix_problem("        target: [lock-parse, gone]\n", ["lock-parse"]) != ""
expect StaticChecks.fuzz_matrix_problem("jobs:\n", ["lock-parse"]) != ""

expect StaticChecks.workflow_problem("ci.yml", workflow_sample) == ""
expect StaticChecks.workflow_problem("ci.yml", workflow_sample.replace_each("permissions: {}", "permissions:\n  contents: read")) == "ci.yml must set top-level permissions: {} and state permissions per job"
expect StaticChecks.workflow_problem("ci.yml", workflow_sample.replace_each("          persist-credentials: false\n", "")) == "ci.yml: every actions/checkout step must set persist-credentials: false"

# A job's own empty permissions are indented, so they are not the top-level setting.
expect StaticChecks.workflow_problem("ci.yml", "jobs:\n  test:\n    permissions: {}\n") != ""

expect StaticChecks.constant("  roc_overlay : Str\n  roc_overlay = \"abc\"\n", "roc_overlay") == Ok("abc")
expect StaticChecks.constant("            version = \"0.4.0-rc2\";\n", "version") == Ok("0.4.0-rc2")
expect StaticChecks.constant("my_version = \"1\"\n", "version") == Err(NoConstant)

expect StaticChecks.core_modules_problem(["main.roc", "Spec.roc"], ["Spec.roc", "main.roc"]) == ""
expect StaticChecks.core_modules_problem(["main.roc", "Spec.roc", "New.roc"], ["main.roc", "Spec.roc", "Old.roc"]) == "flake.nix must list exactly the modules of blueprint-core (not listed: New.roc; listed but absent: Old.roc)"

expect StaticChecks.version_problem("  version = \"0.4.0\";\n", "version = \"0.4.0\"\n") == ""
expect StaticChecks.version_problem("  version = \"0.4.0\";\n", "version = \"0.4.1\"\n") == "flake.nix packages version 0.4.0, but blueprint-cli/main.roc reports 0.4.1"
expect StaticChecks.version_problem("", "version = \"0.4.1\"\n") != ""

expect StaticChecks.lock_inspector_contract_problem("import core.Lock\nimport core.Provider\n") == ""
expect !StaticChecks.lock_inspector_contract_problem("import nix.Locks\n").is_empty()
expect !StaticChecks.lock_inspector_contract_problem("import pf.Path\n").is_empty()

expect StaticChecks.lock_inspector_contract_problem("import core.Value\nimport ReportJson\n") == ""
expect !StaticChecks.lock_inspector_contract_problem("import Store\n").is_empty()

expect StaticChecks.core_report_contract_problem("import Lock\nimport JsonData\n") == ""
expect !StaticChecks.core_report_contract_problem("import nix.NixProvider\n").is_empty()
expect !StaticChecks.core_report_contract_problem("import pf.Path\n").is_empty()
