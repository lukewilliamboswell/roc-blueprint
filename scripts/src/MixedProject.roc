import cli.Env
import cli.Path
import Process
import Script
import FlakeLock
import "../../blueprint-cli/compiler-version" as compiler_version : Str
import "../../fixtures/consumer/inputs.lock" as fixture_lock : Str

## Native acceptance evidence: Linux publishes the project and authority;
## Windows consumes those exact bytes, without resolving Nix inputs again.
MixedProject := [].{
	run! = |binary, producer| {
		root = Process.portable(Path.to_str(Path.canonicalize!(Env.cwd!()?)?)?)
		blueprint = Process.portable(Path.to_str(Path.canonicalize!(Path.utf8(binary))?)?)
		project = "${root}/.cache/mixed-project"
		config_path = Path.utf8("${project}/Blueprint.roc")
		lock_path = Path.utf8("${project}/Blueprint.lock")
		if producer {
			Path.create_all!(Path.utf8(project))?
			pin = FlakeLock.locked(fixture_lock, "nixpkgs").map_err(|_| MissingPin)?.rev
			config = Str.join_with(
				[
					"app [config] { pf: platform \"../../blueprint-platform/main.roc\" }",
					"import pf.Recipes",
					"config = [",
					"Name(\"mixed-native\"),",
					"Systems([\"x86_64-linux\", \"x86_64-windows\"]),",
					"Packages(\"nix\", From(NixPackages(\"github:NixOS/nixpkgs/${pin}\"))),",
					"Executor(\"native\", Nix(\"nix\")),",
					"Environment(\"base\", [ToolsFor(\"x86_64-linux\", [\"nix#git\"])]),",
					"Environment(\"unix\", [Extend(\"base\")]),",
					"Task(\"git\", [Use(\"unix\"), Run([\"git\", \"--version\"])]),",
					"Environment(\"portable\", [Programs([Fetch(\"roc-stable\", Recipes.roc_nightly(\"${compiler_version.trim()}\"))])]),",
					"Task(\"portable\", [Use(\"portable\"), Run([\"roc-stable\", \"version\"])]),",
					"Build(\"artifact\", [Execute(\"native\"), Use(\"unix\"), Files([\"Blueprint.roc\"]), Run([\"git\", \"--version\"]), Output(\"out\")]),",
					"]",
					"",
				],
				"\n",
			)
			config_path.write_utf8!(config)?
			_ = Process.succeed!(Process.command(blueprint, ["check"], project))?
			_ = Process.succeed!(Process.command(blueprint, ["update"], project))?
			git = Process.succeed!(Process.command(blueprint, ["run", "git"], project))?
			Process.check!(git.stdout.starts_with("git version "), "mixed project's Nix task did not run Git")?
		}
		before = lock_path.read_utf8!()?
		config = config_path.read_utf8!()?
		if !producer {
			Process.check!(Process.holding!(Process.search_path!(), "nix").is_empty(), "Windows acceptance requires no Nix on PATH")?
		}
		report = Process.succeed!(Process.command(blueprint, ["requirements", "--json", "portable"], project))?
		parsed : { providers : List(Str) }
		parsed = Json.parse(report.stdout).map_err(|_| InvalidReport)?
		Process.check!(parsed.providers.is_empty(), "portable task unexpectedly requires a provider: ${report.stdout}")?
		portable = Process.succeed!(Process.command(blueprint, ["run", "portable"], project))?
		Process.check!(portable.stdout.contains(compiler_version.trim()), "portable task did not execute the locked compiler")?
		Process.check!(lock_path.read_utf8!()? == before, "execution changed the shared lock")?
		if !producer {
			# Remove local execution products before each refusal. A real ambient
			# Git exists on the runner; it must never mask an unsupported tool.
			Path.delete_all!(Path.utf8("${project}/.blueprint"))?
			for (args, diagnostic) in [
				(["build", "artifact"], "sandboxed builds currently require target x86_64-linux"),
				(["run", "git"], "unsupported Nix target x86_64-windows"),
			] {
				config_path.write_utf8!(config.replace_each("ToolsFor(\"x86_64-linux\", [\"nix#git\"])", "Tools([\"nix#git\"])"))?
				refused = Process.capture!(Process.command(blueprint, args, project))?
				Process.check!(refused.code != 0 and refused.stderr.contains(diagnostic), "wrong refusal: ${refused.stdout}${refused.stderr}")?
				Process.check!(!Path.exists!(Path.utf8("${project}/.blueprint"))?, "unsupported request provisioned a workspace")?
				Process.check!(lock_path.read_utf8!()? == before, "unsupported request changed authority")?
			}
			config_path.write_utf8!(config)?
		}
		Script.pass!("mixed project uses one Linux-produced lock on ${if producer "Linux with Nix" else "Windows without Nix"}")
	}
}
