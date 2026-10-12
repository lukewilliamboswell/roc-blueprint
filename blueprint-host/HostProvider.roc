# Pure planning for a host that has no Nix: what a task needs is fetched or
# found on the machine itself.
import core.Spec
import core.Project
import core.Request
import core.Layout
import core.Steps
import core.Provider

## A stop-gap for Windows, where Nix does not run. It realises a task and
## nothing else: no shell, no sandboxed build, and no pins of its own. The
## Lock is the one `blueprint update` wrote on Linux or macOS; the Core reads
## it for staleness and its Nix pins are not used here.
HostProvider :: [].{
	provider : Provider
	provider = Provider.{
		name: "host",
		# What a Blueprint.roc may require and still load here. Loading is not
		# realising: `preflight` refuses what this provider cannot do.
		features: ["raw", "sources", "builds", "workflows", "system-tools", "commands", "roc-packages", "configured-tools", "programs", "expects"],
		render: |spec| {
			_ = Project.validate(spec)?
			Ok([])
		},
		preflight,
		realise: |spec, request, target, layout, _lock| plan(spec, request, target, layout).map_err(|message| Unrealisable(message)),
		resolve: |_spec, _target, _layout, _update| Err(no_pins),
		lock_from_native: |_spec, _layout, _text, _trees| Err(no_pins),
		compiler,
	}

	## The compiler that evaluates Blueprint.roc, fetched from roc-lang/nightlies
	## into the generated root. Its digest is recorded in `compilers`: the Lock
	## cannot hold it, because a project has no Lock until it has been
	## evaluated.
	compiler : Str, Str, Layout -> Try(Provider.Compiler, Str)
	compiler = |tag, target, layout| {
		check_layout(layout)?
		release = nightly(tag, target)?
		recorded = compilers.find_first(|entry| entry.tag == tag and entry.system == target)
			.map_err(|_| "no digest is recorded for Roc ${tag} on ${target}")?
		Ok(
			Fetched(
				fetched(
					release,
					target,
					"${layout.generated_root}/host/roc/${tag}",
					"${release.top}/${release.executable}",
					[],
					Recorded(recorded.sha256),
				),
			),
		)
	}

	## The SHA-256 of each archive `compiler` fetches, as the release of
	## roc-lang/nightlies with that tag reports it. scripts/test.roc requires
	## an entry for the nightly in blueprint-cli/compiler-version.
	compilers : List({ tag : Str, system : Str, sha256 : Str })
	compilers = [
		{ tag: "nightly-2026-10-04-130536d", system: "x86_64-windows", sha256: "1f5ac14286ebea19f884176c6ab1eabe29f1ad58c10d8f490a9c282e0411033f" },
		{ tag: "nightly-2026-10-04-130536d", system: "x86_64-linux", sha256: "893c86d2da0a4c390cbdbd4258ce45d686e5ec15b42eeeb811fd1ac44537714f" },
		{ tag: "nightly-2026-10-04-130536d", system: "aarch64-linux", sha256: "f4532d290c83920d23f191da4650b19aa8302743ed35cab4e9adc83beaf0c1db" },
		{ tag: "nightly-2026-10-04-130536d", system: "aarch64-darwin", sha256: "e0147f62f072a309519cbc2a6ebfa11e4bb8bac7903d5febaf7a112d1fc2842f" },
		{ tag: "nightly-2026-10-04-130536d", system: "x86_64-darwin", sha256: "cd8df0772cc1d831acea9ebe000340d244297e37393e4d0a8b581f8300422fd4" },
	]

	## One compiler archive of a roc-lang/nightlies release: the asset, the
	## directory it unpacks to, and the compiler's name in it.
	Nightly : { tag : Str, asset : Str, top : Str, executable : Str }

	nightly : Str, Str -> Try(Nightly, Str)
	nightly = |tag, target| {
		if !nightly_tag(tag) {
			return Err("not a Roc nightly tag: ${tag}")
		}
		{ build, extension } = match target {
			"x86_64-windows" => { build: "windows_x86_64", extension: ".zip" }
			"x86_64-linux" => { build: "linux_x86_64", extension: ".tar.gz" }
			"aarch64-linux" => { build: "linux_arm64", extension: ".tar.gz" }
			"aarch64-darwin" => { build: "macos_apple_silicon", extension: ".tar.gz" }
			"x86_64-darwin" => { build: "macos_x86_64", extension: ".tar.gz" }
			_ => return Err("unsupported host target: ${target}")
		}
		top = "roc_nightly-${build}-${tag.drop_prefix("nightly-")}"
		Ok({ tag, asset: "${top}${extension}", top, executable: "roc${suffix(target)}" })
	}

	## `nightly-YYYY-MM-DD-<commit>`, as roc-lang/nightlies names a release.
	nightly_tag : Str -> Bool
	nightly_tag = |tag| {
		digits = |part, count| part.to_utf8().len() == count and part.to_utf8().all(|b| b >= '0' and b <= '9')
		match tag.split_on("-") {
			["nightly", year, month, day, commit] =>
				digits(year, 4) and digits(month, 2) and digits(day, 2)
					and commit.to_utf8().len() >= 7 and commit.to_utf8().len() <= 40
						and commit.to_utf8().all(|b| (b >= '0' and b <= '9') or (b >= 'a' and b <= 'f'))

			_ => False
		}
	}

	## The nightly a command's tool names. A Blueprint.roc names a compiler as
	## an attribute of roc-overlay, `rocpkgs.nightly-2026-10-04-130536d`, with
	## the tag quoted or not; that tag is also the release's.
	command_nightly : Spec.Tool -> Try(Str, [NotANightly])
	command_nightly = |tool|
		match Project.nix_path(tool.name) {
			Ok(["rocpkgs", tag]) if nightly_tag(tag) => Ok(tag)
			_ => Err(NotANightly)
		}

	## An executable's suffix on a System.
	suffix : Str -> Str
	suffix = |target| if target.ends_with("-windows") ".exe" else ""

	## The programs that download and unpack. Windows has shipped curl and
	## bsdtar, which reads a zip, in System32 since 1803. They are named in
	## full there: under Git's bash, as on a GitHub runner, `tar` is GNU tar,
	## which does not. The drive is assumed to be C:, as a provider cannot ask.
	programs : Str -> { curl : Str, tar : Str }
	programs = |target|
		if target.ends_with("-windows") {
			{ curl: "C:/Windows/System32/curl.exe", tar: "C:/Windows/System32/tar.exe" }
		} else {
			{ curl: "curl", tar: "tar" }
		}

	## Texts the executor replaces (see `Steps.Archive`). A task's own argv is
	## never rewritten, so it may hold them.
	archive_text : Str
	archive_text = "@blueprint-host-archive@"

	tree_text : Str
	tree_text = "@blueprint-host-tree@"

	token_text : Str
	token_text = "@blueprint-host-token@"

	## Only HTTPS, and a failed transfer is a failed command.
	transfer : List(Str)
	transfer = ["--fail", "--silent", "--show-error", "--location", "--proto", "=https", "--retry", "3"]

	fetched : Nightly, Str, Str, Str, List({ from : Str, to : Str }), Steps.Digest -> Steps.Archive
	fetched = |release, target, directory, program, moves, digest| {
		{ curl, tar } = programs(target)
		{
			directory,
			program,
			archive: archive_text,
			tree: tree_text,
			download: [curl].concat(transfer).concat(["--output", archive_text, "https://github.com/roc-lang/nightlies/releases/download/${release.tag}/${release.asset}"]),
			unpack: [tar, "-xf", archive_text, "-C", tree_text],
			moves,
			digest,
		}
	}

	## The digest GitHub reports for a release asset, asked when the step
	## runs. With a token the request is not counted against the limit that
	## machines sharing an address, as hosted runners do, exhaust together.
	published : Nightly, Str -> Steps.Digest
	published = |release, target| {
		{ curl, .. } = programs(target)
		ask = [curl].concat(transfer).concat(["--header", "Accept: application/vnd.github+json", "https://api.github.com/repos/roc-lang/nightlies/releases/tags/${release.tag}"])
		Published({
			asset: release.asset,
			ask,
			# curl reads the header from a configuration on its standard input,
			# so the token is in no argv.
			authorized: ask.concat(["--config", "-"]),
			token: { text: token_text, input: "header = \"Authorization: Bearer ${token_text}\"\n", variables: ["GH_TOKEN", "GITHUB_TOKEN"] },
		})
	}

	## A command of an environment, fetched as the one program in a directory
	## of its own, so that the directory can go on PATH and add nothing else.
	command_archive : Spec.Command, Str, Layout -> Try({ archive : Steps.Archive, executable : Str }, [NotANightly])
	command_archive = |command, target, layout| {
		tag = command_nightly(command.tool)?
		release = nightly(tag, target).map_err(|_| NotANightly)?
		directory = "${layout.generated_root}/host/commands/${command.name}/${tag}"
		program = "bin/${command.name}${suffix(target)}"
		Ok({
			archive: fetched(release, target, directory, program, [{ from: "${release.top}/${release.executable}", to: program }], published(release, target)),
			executable: "${directory}/${program}",
		})
	}

	## The Systems this provider can realise a task on.
	supported_systems : List(Str)
	supported_systems = ["x86_64-windows", "x86_64-linux", "aarch64-linux", "aarch64-darwin", "x86_64-darwin"]

	no_pins : Str
	no_pins = "pins are resolved with Nix, which this host does not have; run `blueprint update` on Linux or macOS and commit Blueprint.lock"

	no_builds : Str
	no_builds = "a sandboxed build needs Nix on Linux, which this host does not have"

	preflight : Spec, Request, Str, Layout -> Try({}, Str)
	preflight = |spec, request, target, layout| {
		_ = plan(spec, request, target, layout)?
		Ok({})
	}

	## Every check precedes the first step: a request is planned whole or not
	## at all.
	plan : Spec, Request, Str, Layout -> Try(Steps, Str)
	plan = |spec, request, target, layout| {
		project = Project.validate(spec)?
		check_layout(layout)?
		if !supported_systems.contains(target) {
			return Err("unsupported host target: ${target}")
		}
		match request {
			# Nothing is generated: no file of this provider outlives a task.
			Request.Generate => Ok(Steps.{ steps: [] })
			Request.Shell(_) => Err("a shell needs Nix, which this host does not have; run the task with `blueprint run`")
			Request.Build(_) => Err(no_builds)
			Request.Run(name, extra) => Ok(Steps.{ steps: [task_step(project, name, extra, target, layout)?] })
			Request.Workflow(name) => {
				var $steps = []
				for step in Project.workflow_steps(project, name)? {
					match step {
						RunTask(task, extra) => {
							$steps = $steps.append(task_step(project, task, extra, target, layout)?)
						}
						BuildArtifact(_) => return Err(no_builds)
					}
				}
				Ok(Steps.{ steps: $steps })
			}
		}
	}

	## A task's argv, run from the project root with what its environment
	## declares.
	task_step : Spec, Str, List(Str), Str, Layout -> Try(Steps.Step, Str)
	task_step = |project, name, extra, target, layout| {
		task = project.tasks.find_first(|t| t.name == name)
			.map_err(|_| "unknown task: ${name}")?
		argv = task.run.concat(extra)
		Project.check_argv(argv, name)?
		Project.provider_alone(project, task.environment)?
		probes = environment_probes(project, task.environment, target)?
		commands = environment_commands(project, task.environment, target, layout)?
		bundles = environment_bundles(project, task.environment, target)?
		# What the host lacks is said before anything is downloaded.
		fetches = (if probes.is_empty() [] else [Require(probes)])
			.concat(commands.map(|command| Fetch(command.archive)))
			.concat(if bundles.is_empty() [] else [RocBundles({ compiler: compiler_text, bundles })])
		Ok({
			action: Run(name),
			files: [],
			argv: started(argv, commands, task, target, layout)?,
			artifacts: [],
			# The task's own children find the commands as the task does.
			operations: if commands.is_empty() fetches else fetches.append(Search(commands.map(|command| command.directory))),
		})
	}

	## An environment's commands, each with the archive that supplies it. Only
	## a Roc nightly can be fetched; every other command is named in one
	## refusal.
	environment_commands : Spec, Str, Str, Layout -> Try(List(Supplied), Str)
	environment_commands = |project, name, target, layout| {
		declared = project.commands.keep_if(|entry| entry.environment == name)
		var $supplied = []
		var $refused = []
		for command in declared {
			match command_archive(command, target, layout) {
				Ok({ archive, executable }) => {
					$supplied = $supplied.append({ name: command.name, archive, executable, directory: "${archive.directory}/bin" })
				}
				Err(NotANightly) => {
					$refused = $refused.append("${command.name} (${tool_text(command.tool)})")
				}
			}
		}
		if $refused.is_empty() {
			Ok($supplied)
		} else {
			Err("environment ${name} declares commands this host cannot supply: ${Str.join_with($refused, ", ")}; only a Roc nightly can be fetched, as in Command(\"roc-stable\", \"rocpkgs.nightly-2026-10-04-130536d\")")
		}
	}

	## An environment's Roc packages, each downloaded from the URL its
	## Blueprint.roc gives and unpacked by the compiler. A bundle's name is the
	## hash of its bytes, which `roc unbundle` checks; the Lock's own digest
	## of the bundle is of the tree as Nix unpacks it, and is not used here.
	environment_bundles : Spec, Str, Str -> Try(List({ name : Str, download : List(Str), unbundle : List(Str) }), Str)
	environment_bundles = |project, name, target| {
		{ curl, .. } = programs(target)
		var $bundles = []
		for entry in project.roc_packages.keep_if(|declared| declared.environment == name) {
			source = project.build_sources.find_first(|declared| declared.name == entry.source)
				.map_err(|_| "unknown source of Roc package ${entry.name}: ${entry.source}")?
			url = source.ref.drop_prefix("tarball+")
			file = "${entry.name}.tar.zst"
			if !Project.valid_name(entry.name) or !source.ref.starts_with("tarball+https://") or !url.ends_with("/${file}") {
				return Err("Roc package ${entry.name} is not a bundle this host can download: ${source.ref}")
			}
			$bundles = $bundles.append({
				name: entry.name,
				download: [curl].concat(transfer).concat(["--output", file, url]),
				unbundle: [compiler_text, "unbundle", file],
			})
		}
		Ok($bundles)
	}

	## The text the executor replaces with its compiler (see `Steps.Operation`).
	compiler_text : Str
	compiler_text = "@blueprint-host-compiler@"

	## A command an environment declares, where its program will be, and the
	## directory that holds that program alone.
	Supplied : { name : Str, archive : Steps.Archive, executable : Str, directory : Str }

	## The command every Roc script names on its first line,
	## `#!/usr/bin/env roc-stable`.
	script_command : Str
	script_command = "roc-stable"

	## The argv that starts a task. A task that starts one of its
	## environment's commands starts the fetched program itself. Windows does
	## not read a script's first line, so a Roc script is started as the line
	## asks everywhere: by `roc-stable`, with the script and then its
	## arguments. Any other program named by a relative path is in the project,
	## whatever directory the caller is in.
	started : List(Str), List(Supplied), Spec.Task, Str, Layout -> Try(List(Str), Str)
	started = |argv, commands, task, target, layout|
		match argv {
			[program, .. as rest] =>
				if program.ends_with(".roc") {
					match commands.find_first(|command| command.name == script_command) {
						Ok(command) => Ok([command.executable].concat(argv))
						Err(_) => Err("task ${task.name} runs the Roc script ${program}, which ${script_command} starts; give environment ${task.environment} a Command(\"${script_command}\", ...) that names a Roc nightly")
					}
				} else {
					match commands.find_first(|command| command.name == program) {
						Ok(command) => Ok([command.executable].concat(rest))
						Err(_) => Ok([in_project(program, target, layout)].concat(rest))
					}
				}

			[] => Ok(argv)
		}

	## A program as the process API finds it. A bare name is left to PATH and
	## an absolute path is itself; a relative path is taken from the project
	## root, where a task runs.
	in_project : Str, Str, Layout -> Str
	in_project = |program, target, layout| {
		text = if target.ends_with("-windows") program.replace_each("\\", "/") else program
		if !text.contains("/") or absolute(text) {
			program
		} else {
			root = if layout.project_root.ends_with("/") layout.project_root.drop_suffix("/") else layout.project_root
			parts = text.split_on("/").fold(
				root.split_on("/"),
				|kept, part|
					match part {
						"" | "." => kept
						".." => if kept.len() > 1 kept.drop_last(1) else kept
						_ => kept.append(part)
					},
			)
			if parts.len() == 1 "${Str.join_with(parts, "/")}/" else Str.join_with(parts, "/")
		}
	}

	## An environment's tools, and those it declares for this System, as
	## programs the host must already have. Nothing is installed: a tool is
	## known here by what proves it present, and one that is not known is
	## refused, all of them in one message. A tool's source says which Nix
	## package set it comes from and means nothing here, and neither do the
	## options of a configured tool: nothing on the host says which targets
	## or components a toolchain was installed with.
	environment_probes : Spec, Str, Str -> Try(List(Steps.Probe), Str)
	environment_probes = |project, name, target| {
		environment = project.environments.find_first(|e| e.name == name)
			.map_err(|_| "unknown environment: ${name}")?
		tools = environment.tools.concat(
			project.system_tools.keep_if(|entry| entry.environment == name and entry.system == target)
				.fold([], |all, entry| all.concat(entry.tools)),
		).concat(project.configured_tools.keep_if(|entry| entry.environment == name).map(|entry| entry.tool))
		var $probes = []
		var $unknown = []
		for tool in tools {
			match tool_probes(tool) {
				Ok(known) => {
					$probes = $probes.concat(known)
				}
				Err(UnknownTool) => {
					$unknown = $unknown.append(tool_text(tool))
				}
			}
		}
		if $unknown.is_empty() {
			Ok($probes)
		} else {
			Err("environment ${name} declares tools this host cannot check for: ${Str.join_with($unknown, ", ")}; it knows ${known_tools}")
		}
	}

	known_tools : Str
	known_tools = "git, gh, gnutar, zip, unzip, go, zig, zigpkgs.\"<version>\", cargo, rustc and rust-bin.stable.\"<version>\".default"

	## How a tool is shown to be on the host. A name that carries a version,
	## as zig-overlay's and rust-overlay's attributes do, asks for that
	## version; any other is satisfied by whichever the host has.
	tool_probes : Spec.Tool -> Try(List(Steps.Probe), [UnknownTool])
	tool_probes = |tool| {
		text = tool_text(tool)
		any = |program, arguments| Ok([{ tool: text, probe: [program].concat(arguments), version: Any }])
		match Project.nix_path(tool.name) {
			Ok(["git"]) => any("git", ["--version"])
			Ok(["gh"]) => any("gh", ["--version"])
			Ok(["gnutar"]) => any("tar", ["--version"])
			Ok(["zip"]) => any("zip", ["-v"])
			Ok(["unzip"]) => any("unzip", ["-v"])
			Ok(["go"]) => any("go", ["version"])
			Ok(["zig"]) => any("zig", ["version"])
			Ok(["cargo"]) => any("cargo", ["--version"])
			Ok(["rustc"]) => any("rustc", ["--version"])
			Ok(["zigpkgs", version]) if release_version(version) => Ok([{ tool: text, probe: ["zig", "version"], version: Is(version) }])
			Ok(["rust-bin", "stable", version, "default"]) if release_version(version) =>
				Ok([
					{ tool: text, probe: ["rustc", "--version"], version: Starts("rustc ${version} ") },
					{ tool: text, probe: ["cargo", "--version"], version: Starts("cargo ${version} ") },
				])

			_ => Err(UnknownTool)
		}
	}

	## `1.95.0`: numbers between dots, as a release is numbered.
	release_version : Str -> Bool
	release_version = |version| {
		parts = version.split_on(".")
		parts.len() == 3 and parts.all(|part| !part.is_empty() and part.to_utf8().all(|b| b >= '0' and b <= '9'))
	}

	## A tool as Blueprint.roc writes it.
	tool_text : Spec.Tool -> Str
	tool_text = |tool| if tool.source == "default" tool.name else "${tool.source}#${tool.name}"

	## Core `Layout.validate` knows POSIX paths alone, and a Windows layout
	## starts at a drive (`D:/a/project`). The CLI normalizes every path before
	## a provider sees it; this refuses text a plan could not carry.
	check_layout : Layout -> Try({}, Str)
	check_layout = |layout| {
		for path in [layout.project_root, layout.workspace, layout.generated_root, layout.lock_path] {
			if !absolute(path) or path.to_utf8().any(|b| b < 32 or b == 127 or b == '\\' or b == '"') or path.split_on("/").drop_first(1).any(|part| part == "." or part == "..") {
				return Err("layout paths must be normalized absolute paths")
			}
		}
		Ok({})
	}
}

absolute : Str -> Bool
absolute = |path|
	match path.to_utf8() {
		['/', ..] => True
		[letter, ':', '/', ..] => (letter >= 'a' and letter <= 'z') or (letter >= 'A' and letter <= 'Z')
		_ => False
	}

## A plan's steps: `Steps` itself has no equality.
planned : Spec, Request, Str, Layout -> Try(List(Steps.Step), Str)
planned = |spec, request, target, layout| HostProvider.plan(spec, request, target, layout).map_ok(|steps| steps.steps)

windows : Layout
windows = Layout.{
	project_root: "D:/a/project",
	workspace: "D:/a/project/.blueprint",
	generated_root: "D:/a/project/.blueprint",
	lock_path: "D:/a/project/Blueprint.lock",
}

sample : Spec
sample = {
	..Spec.empty("sample"),
	systems: ["x86_64-linux", "x86_64-windows"],
	requires_: ["system-tools"],
	sources: [{ name: "default", provider: Auto }, { name: "py", provider: Auto }, { name: "rust", provider: Auto }],
	system_tools: [
		{ environment: "ci", system: "x86_64-windows", tools: [{ source: "default", name: "unzip" }] },
		{ environment: "ci", system: "x86_64-linux", tools: [{ source: "default", name: "go" }] },
	],
	environments: [
		{ name: "plain", parents: [], tools: [], overlays: [] },
		{ name: "dev", parents: ["plain"], tools: [{ source: "default", name: "git" }, { source: "py", name: "python314" }, { source: "default", name: "ripgrep" }], overlays: [] },
		{ name: "host", parents: [], tools: [{ source: "default", name: "git" }, { source: "default", name: "zigpkgs.\"0.16.0\"" }, { source: "rust", name: "rust-bin.stable.\"1.95.0\".default" }], overlays: [] },
		{ name: "ci", parents: ["host"], tools: [{ source: "default", name: "gnutar" }], overlays: [] },
	],
	shells: [{ name: "default", environment: "plain" }],
	tasks: [
		{ name: "hello", environment: "plain", run: ["hello.exe", "configured"] },
		{ name: "tooled", environment: "dev", run: ["git", "status"] },
		{ name: "release", environment: "ci", run: ["zig", "build"] },
	],
}

# A task with nothing to supply is its argv, with the caller's arguments last.
expect planned(sample, Request.Run("hello", ["extra"]), "x86_64-windows", windows) == Ok([{ action: Run("hello"), files: [], argv: ["hello.exe", "configured", "extra"], artifacts: [], operations: [] }])
expect planned(sample, Request.Generate, "x86_64-windows", windows) == Ok([])
expect planned(sample, Request.Run("absent", []), "x86_64-windows", windows) == Err("unknown task: absent")

# What Nix alone does is refused, saying so.
expect planned(sample, Request.Shell("default"), "x86_64-windows", windows) == Err("a shell needs Nix, which this host does not have; run the task with `blueprint run`")
expect planned(sample, Request.Build("app"), "x86_64-windows", windows) == Err(HostProvider.no_builds)
expect (HostProvider.provider.resolve)(sample, "x86_64-windows", windows, All) == Err(HostProvider.no_pins)
expect (HostProvider.provider.lock_from_native)(sample, windows, "{}", []) == Err(HostProvider.no_pins)

expect planned(sample, Request.Run("tooled", []), "x86_64-windows", windows) == Err("environment dev declares tools this host cannot check for: py#python314, ripgrep; it knows ${HostProvider.known_tools}")

expect planned(sample, Request.Run("hello", []), "riscv64-linux", windows) == Err("unsupported host target: riscv64-linux")
expect planned(sample, Request.Run("hello", []), "x86_64-linux", { ..windows, project_root: "/home/me/project" }).is_ok()
expect
	["project", "D:project", "D:\\a\\project", "D:/a/../project", "D:/a/\"project"].all(
		|root| planned(sample, Request.Run("hello", []), "x86_64-windows", { ..windows, project_root: root }) == Err("layout paths must be normalized absolute paths"),
	)

expect (HostProvider.provider.render)(sample) == Ok([])

stable : Spec
stable = {
	..sample,
	requires_: ["commands"],
	system_tools: [],
	inputs: [{ name: "roc", url: "github:roc-lang/roc-overlay", kind: Overlay }],
	environments: [
		{ name: "base", parents: [], tools: [], overlays: ["roc"] },
		{ name: "scripts", parents: ["base"], tools: [], overlays: [] },
		{ name: "mixed", parents: ["base"], tools: [], overlays: [] },
	],
	commands: [
		{ environment: "base", name: "roc-stable", tool: { source: "default", name: "rocpkgs.\"nightly-2026-10-04-130536d\"" } },
		{ environment: "mixed", name: "greet", tool: { source: "default", name: "hello" } },
		{ environment: "mixed", name: "latest", tool: { source: "default", name: "rocpkgs.nightly" } },
	],
	shells: [],
	tasks: [
		{ name: "version", environment: "scripts", run: ["roc-stable", "version"] },
		{ name: "other", environment: "scripts", run: ["printf", "roc-stable"] },
		{ name: "check", environment: "scripts", run: ["scripts/check_all.roc", "--quick"] },
		{ name: "local", environment: "scripts", run: ["tools\\report.exe", "roc-stable"] },
		{ name: "greet", environment: "mixed", run: ["greet"] },
	],
}

windows_curl : List(Str)
windows_curl = ["C:/Windows/System32/curl.exe", "--fail", "--silent", "--show-error", "--location", "--proto", "=https", "--retry", "3"]

# An inherited roc-stable is the nightly's roc.exe, alone in a directory, and
# the task starts that file. The digest is the release's own.
expect planned(stable, Request.Run("version", ["--verbose"]), "x86_64-windows", windows) == Ok([
	{
		action: Run("version"),
		files: [],
		argv: ["D:/a/project/.blueprint/host/commands/roc-stable/nightly-2026-10-04-130536d/bin/roc-stable.exe", "version", "--verbose"],
		artifacts: [],
		operations: [
			Fetch({
				directory: "D:/a/project/.blueprint/host/commands/roc-stable/nightly-2026-10-04-130536d",
				program: "bin/roc-stable.exe",
				archive: "@blueprint-host-archive@",
				tree: "@blueprint-host-tree@",
				download: windows_curl.concat(["--output", "@blueprint-host-archive@", "https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-04-130536d/roc_nightly-windows_x86_64-2026-10-04-130536d.zip"]),
				unpack: ["C:/Windows/System32/tar.exe", "-xf", "@blueprint-host-archive@", "-C", "@blueprint-host-tree@"],
				moves: [{ from: "roc_nightly-windows_x86_64-2026-10-04-130536d/roc.exe", to: "bin/roc-stable.exe" }],
				digest: Published({
					asset: "roc_nightly-windows_x86_64-2026-10-04-130536d.zip",
					ask: windows_curl.concat(["--header", "Accept: application/vnd.github+json", "https://api.github.com/repos/roc-lang/nightlies/releases/tags/nightly-2026-10-04-130536d"]),
					authorized: windows_curl.concat(["--header", "Accept: application/vnd.github+json", "https://api.github.com/repos/roc-lang/nightlies/releases/tags/nightly-2026-10-04-130536d", "--config", "-"]),
					token: { text: "@blueprint-host-token@", input: "header = \"Authorization: Bearer @blueprint-host-token@\"\n", variables: ["GH_TOKEN", "GITHUB_TOKEN"] },
				}),
			}),
			Search(["D:/a/project/.blueprint/host/commands/roc-stable/nightly-2026-10-04-130536d/bin"]),
		],
	},
])

# Only the program a task starts is a command; an argument is the task's own.
expect planned(stable, Request.Run("other", []), "x86_64-windows", windows).map_ok(|steps| steps.map(|step| step.argv)) == Ok([["printf", "roc-stable"]])

# Elsewhere the tools are found on PATH and the release is that System's.
expect
	planned(stable, Request.Run("version", []), "aarch64-linux", { ..windows, generated_root: "/project/.blueprint" }).map_ok(
		|steps| steps.map(
			|step| (
				step.argv,
				step.operations.map(
					|operation|
						match operation {
							Fetch(archive) => (archive.download.first() ?? "", archive.unpack.first() ?? "", archive.download.last() ?? "", archive.moves)
							_ => ("", "", "", [])
						},
				),
			),
		),
	) == Ok([
		(
			["/project/.blueprint/host/commands/roc-stable/nightly-2026-10-04-130536d/bin/roc-stable", "version"],
			[("curl", "tar", "https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-04-130536d/roc_nightly-linux_arm64-2026-10-04-130536d.tar.gz", [{ from: "roc_nightly-linux_arm64-2026-10-04-130536d/roc", to: "bin/roc-stable" }]), ("", "", "", [])],
		),
	])

# Every command that is not a pinned nightly is named, in one refusal.
expect planned(stable, Request.Run("greet", []), "x86_64-windows", windows) == Err("environment mixed declares commands this host cannot supply: greet (hello), latest (rocpkgs.nightly); only a Roc nightly can be fetched, as in Command(\"roc-stable\", \"rocpkgs.nightly-2026-10-04-130536d\")")

expect HostProvider.command_nightly({ source: "default", name: "rocpkgs.nightly-2026-10-04-130536d" }) == Ok("nightly-2026-10-04-130536d")
expect HostProvider.command_nightly({ source: "roc", name: "rocpkgs.\"nightly-2026-10-04-130536d\"" }) == Ok("nightly-2026-10-04-130536d")
expect
	["rocpkgs.nightly", "nightly-2026-10-04-130536d", "rocpkgs.nightly-2026-10-04-130536d.extra", "zigpkgs.nightly-2026-10-04-130536d", "rocpkgs.nightly-2026-10-4-130536d", "rocpkgs.nightly-2026-10-04-13053", "rocpkgs.nightly-2026-10-04-130536D", "rocpkgs.\"nightly-2026-10-04-130536d/..\""].all(
		|name| HostProvider.command_nightly({ source: "default", name }) == Err(NotANightly),
	)

# The compiler that evaluates Blueprint.roc is kept whole, by a recorded digest.
expect (HostProvider.provider.compiler)("nightly-2026-10-04-130536d", "x86_64-windows", windows) == Ok(
	Fetched({
		directory: "D:/a/project/.blueprint/host/roc/nightly-2026-10-04-130536d",
		program: "roc_nightly-windows_x86_64-2026-10-04-130536d/roc.exe",
		archive: "@blueprint-host-archive@",
		tree: "@blueprint-host-tree@",
		download: windows_curl.concat(["--output", "@blueprint-host-archive@", "https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-04-130536d/roc_nightly-windows_x86_64-2026-10-04-130536d.zip"]),
		unpack: ["C:/Windows/System32/tar.exe", "-xf", "@blueprint-host-archive@", "-C", "@blueprint-host-tree@"],
		moves: [],
		digest: Recorded("1f5ac14286ebea19f884176c6ab1eabe29f1ad58c10d8f490a9c282e0411033f"),
	}),
)
expect (HostProvider.provider.compiler)("nightly-2026-10-03-c507926", "x86_64-windows", windows) == Err("no digest is recorded for Roc nightly-2026-10-03-c507926 on x86_64-windows")
expect (HostProvider.provider.compiler)("0.1.0", "x86_64-windows", windows) == Err("not a Roc nightly tag: 0.1.0")

# One recorded digest for each System a task can run on, each 64 hex digits.
expect HostProvider.supported_systems.all(|system| HostProvider.compilers.keep_if(|entry| entry.system == system).len() == 1)
expect HostProvider.compilers.all(|entry| entry.sha256.to_utf8().len() == 64 and entry.sha256.to_utf8().all(|b| (b >= '0' and b <= '9') or (b >= 'a' and b <= 'f')))

# A Roc script is started as its first line asks, with its own path and then
# its arguments; the path stays as the task wrote it, from the project root.
expect planned(stable, Request.Run("check", ["extra"]), "x86_64-windows", windows).map_ok(|steps| steps.map(|step| step.argv)) == Ok([["D:/a/project/.blueprint/host/commands/roc-stable/nightly-2026-10-04-130536d/bin/roc-stable.exe", "scripts/check_all.roc", "--quick", "extra"]])
expect planned(stable, Request.Run("check", []), "x86_64-linux", { ..windows, project_root: "/project", generated_root: "/project/.blueprint" }).map_ok(|steps| steps.map(|step| step.argv)) == Ok([["/project/.blueprint/host/commands/roc-stable/nightly-2026-10-04-130536d/bin/roc-stable", "scripts/check_all.roc", "--quick"]])

# Without the command there is nothing to start the script with.
expect planned({ ..sample, tasks: [{ name: "check", environment: "plain", run: ["scripts/check_all.roc"] }] }, Request.Run("check", []), "x86_64-windows", windows) == Err("task check runs the Roc script scripts/check_all.roc, which roc-stable starts; give environment plain a Command(\"roc-stable\", ...) that names a Roc nightly")

# A program in the project is named in full, in either Windows spelling.
expect planned(stable, Request.Run("local", []), "x86_64-windows", windows).map_ok(|steps| steps.map(|step| step.argv)) == Ok([["D:/a/project/tools/report.exe", "roc-stable"]])
expect HostProvider.in_project("./tools/../bin/report", "x86_64-linux", { ..windows, project_root: "/project" }) == "/project/bin/report"
expect HostProvider.in_project("../shared/report", "x86_64-windows", windows) == "D:/a/shared/report"
expect HostProvider.in_project("../../../report.exe", "x86_64-windows", windows) == "D:/report.exe"
expect HostProvider.in_project("tools\\report", "x86_64-linux", { ..windows, project_root: "/project" }) == "tools\\report"
expect ["report", "/usr/bin/report", "C:/tools/report.exe", "C:\\tools\\report.exe"].all(|program| HostProvider.in_project(program, "x86_64-windows", windows) == program)

packaged : Spec
packaged = {
	..stable,
	requires_: ["commands", "roc-packages", "sources"],
	roc_packages: [
		{ environment: "base", name: "AEjfyaMFFbh8", source: "roc-AEjfyaMFFbh8" },
		{ environment: "scripts", name: "6ZUwqYhCS8PU", source: "roc-6ZUwqYhCS8PU" },
	],
	build_sources: [
		{ name: "roc-AEjfyaMFFbh8", ref: "tarball+https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8.tar.zst" },
		{ name: "roc-6ZUwqYhCS8PU", ref: "tarball+https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU.tar.zst" },
	],
}

# An environment's bundles, inherited first, are downloaded under their own
# names and unpacked by the compiler, after its commands are fetched.
expect
	planned(packaged, Request.Run("version", []), "x86_64-windows", windows).map_ok(
		|steps| steps.map(
			|step| step.operations.map(
				|operation|
					match operation {
						Fetch(_) => [["fetch"]]
						Search(_) => [["search"]]
						RocBundles({ compiler, bundles }) => [[compiler]].concat(bundles.map(|bundle| [bundle.name])).concat(bundles.map(|bundle| bundle.download)).concat(bundles.map(|bundle| bundle.unbundle))
						_ => []
					},
			).join(),
		),
	) == Ok([
		[
			["fetch"],
			["@blueprint-host-compiler@"],
			["AEjfyaMFFbh8"],
			["6ZUwqYhCS8PU"],
			windows_curl.concat(["--output", "AEjfyaMFFbh8.tar.zst", "https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8.tar.zst"]),
			windows_curl.concat(["--output", "6ZUwqYhCS8PU.tar.zst", "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU.tar.zst"]),
			["@blueprint-host-compiler@", "unbundle", "AEjfyaMFFbh8.tar.zst"],
			["@blueprint-host-compiler@", "unbundle", "6ZUwqYhCS8PU.tar.zst"],
			["search"],
		],
	])

# A bundle is fetched over HTTPS from a file of its own name, or not at all.
expect
	["tarball+http://example.test/AEjfyaMFFbh8.tar.zst", "tarball+https://example.test/other.tar.zst", "https://example.test/AEjfyaMFFbh8.tar.zst", "github:example/AEjfyaMFFbh8.tar.zst"].all(
		|ref| planned({ ..packaged, build_sources: [{ name: "roc-AEjfyaMFFbh8", ref }, { name: "roc-6ZUwqYhCS8PU", ref: "tarball+https://example.test/6ZUwqYhCS8PU.tar.zst" }] }, Request.Run("version", []), "x86_64-windows", windows) == Err("Roc package AEjfyaMFFbh8 is not a bundle this host can download: ${ref}"),
	)

# A tool is a program the host must have, proved before anything else; a name
# that carries a version asks for it. Only this System's tools are asked for.
expect planned(sample, Request.Run("release", []), "x86_64-windows", windows) == Ok([
	{
		action: Run("release"),
		files: [],
		argv: ["zig", "build"],
		artifacts: [],
		operations: [
			Require([
				{ tool: "git", probe: ["git", "--version"], version: Any },
				{ tool: "zigpkgs.\"0.16.0\"", probe: ["zig", "version"], version: Is("0.16.0") },
				{ tool: "rust#rust-bin.stable.\"1.95.0\".default", probe: ["rustc", "--version"], version: Starts("rustc 1.95.0 ") },
				{ tool: "rust#rust-bin.stable.\"1.95.0\".default", probe: ["cargo", "--version"], version: Starts("cargo 1.95.0 ") },
				{ tool: "gnutar", probe: ["tar", "--version"], version: Any },
				{ tool: "unzip", probe: ["unzip", "-v"], version: Any },
			]),
		],
	},
])

expect ["zip", "gh", "go", "zig", "cargo", "rustc"].all(|name| HostProvider.tool_probes({ source: "default", name }).is_ok())
expect
	["python3", "zigpkgs.master", "zigpkgs.\"0.16\"", "rust-bin.nightly.\"2026-10-01\".default", "rust-bin.stable.\"1.95.0\".minimal", "git.doc", "nodejs"].all(
		|name| HostProvider.tool_probes({ source: "default", name }) == Err(UnknownTool),
	)

# A configured tool is asked for as the tool it configures.
expect
	HostProvider.environment_probes(
		{ ..sample, requires_: sample.requires_.append("configured-tools"), configured_tools: [{ environment: "plain", tool: { source: "default", name: "rust-bin.stable.\"1.95.0\".default" }, options: Attrs([]) }] },
		"plain",
		"x86_64-windows",
	).map_ok(|probes| probes.map(|probe| probe.probe))
		== Ok([["rustc", "--version"], ["cargo", "--version"]])

# A fetched program or an expected tool is not this provider's to supply: a
# task whose environment has one is refused, and its neighbours still run.
expect {
	fetching = {
		..sample,
		requires_: sample.requires_.concat(["programs", "expects"]),
		programs: [{ name: "tool", system: "x86_64-windows", urls: ["https://example.test/tool.exe"], unpack: File, path: "" }],
		environments: sample.environments.append({ name: "fetching", parents: ["plain"], tools: [], overlays: [] }).append({ name: "expecting", parents: ["plain"], tools: [], overlays: [] }),
		environment_programs: [{ environment: "fetching", programs: ["tool"] }],
		expects: [{ environment: "expecting", programs: ["git"] }],
		tasks: sample.tasks.append({ name: "fetch", environment: "fetching", run: ["tool"] }).append({ name: "expect", environment: "expecting", run: ["git", "status"] }),
	}
	planned(fetching, Request.Run("fetch", []), "x86_64-windows", windows) == Err("environment fetching has fetched programs or expected tools, which this blueprint reads but cannot yet run with")
		and planned(fetching, Request.Run("expect", []), "x86_64-windows", windows) == Err("environment expecting has fetched programs or expected tools, which this blueprint reads but cannot yet run with")
			and planned(fetching, Request.Run("hello", []), "x86_64-windows", windows).is_ok()
}
