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
		features: ["raw", "sources", "builds", "workflows", "system-tools", "commands", "roc-packages"],
		render: |spec| {
			_ = Project.validate(spec)?
			Ok([])
		},
		preflight,
		realise: |spec, request, target, layout, _lock| plan(spec, request, target, layout).map_err(|message| Unrealisable(message)),
		resolve: |_spec, _target, _layout, _update| Err(no_pins),
		lock_from_native: |_spec, _layout, _text, _trees| Err(no_pins),
		compiler: |_tag| [],
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
			Request.Run(name, extra) => Ok(Steps.{ steps: [task_step(project, name, extra)?] })
			Request.Workflow(name) => {
				var $steps = []
				for step in Project.workflow_steps(project, name)? {
					match step {
						RunTask(task, extra) => {
							$steps = $steps.append(task_step(project, task, extra)?)
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
	task_step : Spec, Str, List(Str) -> Try(Steps.Step, Str)
	task_step = |project, name, extra| {
		task = project.tasks.find_first(|t| t.name == name)
			.map_err(|_| "unknown task: ${name}")?
		argv = task.run.concat(extra)
		Project.check_argv(argv, name)?
		check_environment(project, task.environment)?
		Ok({ action: Run(name), files: [], argv, artifacts: [], operations: [] })
	}

	## What an environment declares that this provider cannot supply.
	check_environment : Spec, Str -> Try({}, Str)
	check_environment = |project, name| {
		environment = project.environments.find_first(|e| e.name == name)
			.map_err(|_| "unknown environment: ${name}")?
		tools = environment.tools.concat(
			project.system_tools.keep_if(|entry| entry.environment == name)
				.fold([], |all, entry| all.concat(entry.tools)),
		)
		commands = project.commands.keep_if(|entry| entry.environment == name)
		bundles = project.roc_packages.keep_if(|entry| entry.environment == name)
		if !tools.is_empty() {
			Err("environment ${name} declares tools, which this host cannot supply: ${Str.join_with(tools.map(tool_text), ", ")}")
		} else if !commands.is_empty() {
			Err("environment ${name} declares commands, which this host cannot supply: ${Str.join_with(commands.map(|entry| entry.name), ", ")}")
		} else if !bundles.is_empty() {
			Err("environment ${name} declares Roc packages, which this host cannot supply")
		} else {
			Ok({})
		}
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
	systems: ["x86_64-linux"],
	sources: [{ name: "default", provider: Auto }, { name: "py", provider: Auto }],
	environments: [
		{ name: "plain", parents: [], tools: [], overlays: [] },
		{ name: "dev", parents: ["plain"], tools: [{ source: "default", name: "git" }, { source: "py", name: "python314" }], overlays: [] },
	],
	shells: [{ name: "default", environment: "plain" }],
	tasks: [
		{ name: "hello", environment: "plain", run: ["hello.exe", "configured"] },
		{ name: "tooled", environment: "dev", run: ["git", "status"] },
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

expect planned(sample, Request.Run("tooled", []), "x86_64-windows", windows) == Err("environment dev declares tools, which this host cannot supply: git, py#python314")

expect planned(sample, Request.Run("hello", []), "riscv64-linux", windows) == Err("unsupported host target: riscv64-linux")
expect planned(sample, Request.Run("hello", []), "x86_64-linux", { ..windows, project_root: "/home/me/project" }).is_ok()
expect
	["project", "D:project", "D:\\a\\project", "D:/a/../project", "D:/a/\"project"].all(
		|root| planned(sample, Request.Run("hello", []), "x86_64-windows", { ..windows, project_root: root }) == Err("layout paths must be normalized absolute paths"),
	)

expect (HostProvider.provider.render)(sample) == Ok([])
