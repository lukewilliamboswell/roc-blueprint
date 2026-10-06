import FlakeLock

## Checks of the repository's own text that need no compiler and no Nix. Each
## returns what is wrong, or "" when nothing is.
StaticChecks := [].{

	## The Roc source directories `roc fmt --check` covers.
	formatted = ["blueprint-core", "blueprint-platform", "blueprint-nix", "blueprint-cli", "fixtures", "examples", "scripts"]

	## Object files, archives and import libraries are fetched by content from
	## the release in `link-inputs.lock.json`; none may be committed.
	binary_patterns = ["*.o", "*.a", "*.lib"]

	tracked_binaries_problem : Str -> Str
	tracked_binaries_problem = |listed| {
		tracked = listed.split_on("\n").keep_if(|line| !line.is_empty())
		if tracked.is_empty() "" else "object files, archives and import libraries must not be committed:\n${Str.join_with(tracked, "\n")}"
	}

	## docs/architecture.adoc invariant 7: the CLI reaches a provider through
	## the Provider contract alone. Its source imports one provider module,
	## names it once, where the provider is selected, and never runs a
	## provider's tool itself.
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

	## Every use of a member of a provider module: an identifier `Locks`, or
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

	## The compiler a released binary fetches comes from the roc-overlay
	## revision the flake locks: `roc_overlay` in the Nix provider is that
	## revision's reference with its content hash.
	overlay_problem : Str, Str -> Str
	overlay_problem = |flake_lock, provider_source|
		match FlakeLock.locked(flake_lock, "roc-overlay") {
			Err(NoPin(_)) => "flake.lock has no GitHub pin for roc-overlay"
			Ok(pin) => {
				expected = FlakeLock.ref_with_hash(pin)
				if constant(provider_source, "roc_overlay") == Ok(expected) "" else "update roc_overlay in NixProvider.roc to ${expected}"
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
			(Ok(packaged), Ok(reported)) => if packaged == reported "" else "flake.nix packages version ${packaged}, but blueprint-cli/main.roc reports ${reported}"
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
	\\provider : Provider
	\\provider = NixProvider.provider
	\\
	\\main! = |_| provider.plan("nix develop")
	\\

lock_sample =
	\\{
	\\  "nodes": {
	\\    "roc-overlay": {
	\\      "locked": {
	\\        "narHash": "sha256-R4Zj+8w/E1L=",
	\\        "owner": "roc-lang",
	\\        "repo": "roc-overlay",
	\\        "rev": "fb02fef7",
	\\        "type": "github"
	\\      }
	\\    }
	\\  }
	\\}

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
expect StaticChecks.provider_references("a = Locks.decode\nb = NixProvider.plan(Nix.x)") == ["Locks", "NixProvider", "Nix"]
expect StaticChecks.provider_references("Locks.") == ["Locks"]

expect StaticChecks.overlay_problem(lock_sample, "\troc_overlay = \"github:roc-lang/roc-overlay/fb02fef7?narHash=sha256-R4Zj%2B8w%2FE1L%3D\"\n") == ""
expect StaticChecks.overlay_problem(lock_sample, "\troc_overlay = \"github:roc-lang/roc-overlay/00000000?narHash=sha256-R4Zj%2B8w%2FE1L%3D\"\n") == "update roc_overlay in NixProvider.roc to github:roc-lang/roc-overlay/fb02fef7?narHash=sha256-R4Zj%2B8w%2FE1L%3D"
expect StaticChecks.overlay_problem(lock_sample, "nothing here") != ""
expect StaticChecks.overlay_problem("{}", "roc_overlay = \"x\"") == "flake.lock has no GitHub pin for roc-overlay"

expect StaticChecks.constant("  roc_overlay : Str\n  roc_overlay = \"abc\"\n", "roc_overlay") == Ok("abc")
expect StaticChecks.constant("            version = \"0.4.0-rc2\";\n", "version") == Ok("0.4.0-rc2")
expect StaticChecks.constant("my_version = \"1\"\n", "version") == Err(NoConstant)

expect StaticChecks.core_modules_problem(["main.roc", "Spec.roc"], ["Spec.roc", "main.roc"]) == ""
expect StaticChecks.core_modules_problem(["main.roc", "Spec.roc", "New.roc"], ["main.roc", "Spec.roc", "Old.roc"]) == "flake.nix must list exactly the modules of blueprint-core (not listed: New.roc; listed but absent: Old.roc)"

expect StaticChecks.version_problem("  version = \"0.4.0\";\n", "version = \"0.4.0\"\n") == ""
expect StaticChecks.version_problem("  version = \"0.4.0\";\n", "version = \"0.4.1\"\n") == "flake.nix packages version 0.4.0, but blueprint-cli/main.roc reports 0.4.1"
expect StaticChecks.version_problem("", "version = \"0.4.1\"\n") != ""
