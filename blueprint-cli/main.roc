## `blueprint`: turns a `Blueprint.roc` into a working Nix environment.
##
## The Roc compiler validates `Blueprint.roc` and prints the blueprint Spec;
## this CLI consumes pure plans and owns file/process effects. Only explicit
## update publishes the authority; ordinary operations use its resolved pins.
app [main!] {
	pf: platform "../.basic-cli/main.roc",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.9.0/7j6KBFBEZ8pNMLQHkx9xiwyZ2PmwQPgKNDPUih6gKe77.tar.zst",
	core: "../blueprint-core/main.roc",
	nix: "../blueprint-nix/main.roc",
}

import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path
import pf.Stdout
import pf.Stderr
import weaver.Cli
import weaver.Param
import weaver.SubCmd
import core.Spec
import core.Project
import core.Request
import core.Steps
import core.Layout
import core.Provider
import core.Lock
import nix.NixProvider
import "../scripts/blueprint-runtime.py" as snapshot_helper : Str
import "../.roc-version" as compiler_version : Str

version : Str
version = "0.2.0"

## The provider every command goes through. This is the only reference to a
## concrete provider: everything else uses the Provider contract
## (docs/architecture.adoc, invariant 7; checked by scripts/test.sh).
provider : Provider
provider = NixProvider.provider

Command : [
	Gen,
	Shell(Str),
	Run({ task : Str, args : List(Str) }),
	Build(Str),
	Workflow(Str),
	Tasks,
	Update,
	Check,
	PrintSpec,
	PrintFlake,
]

## The command-line parser. When Blueprint.roc loads, its shells, tasks and
## builds become subcommands, so help and usage errors list what this project
## actually defines. Otherwise the parser is generic and says why.
cli_for : Try(Spec, _) -> Cli.CliParser(Try(Command, [NoSubcommand]))
cli_for = |loaded| {
	generic_shell_cmd = SubCmd.finish(
		Cli.map(Param.maybe_str({ name: "name", help: "The shell to enter (default: \"default\")." }), |name| Shell(name ?? "default")),
		{ name: "shell", description: "Generate, then enter a dev shell", mapper: |c| c },
	)
	generic_run_cmd = SubCmd.finish(
		{
			task: Param.str({ name: "task", help: "The task to run.", default: NoDefault }),
			args: Param.str_list({ name: "args", help: "Extra arguments for the task; put them after --." }),
		}.Cli,
		{ name: "run", description: "Generate, then run a task in its shell", mapper: |r| Run(r) },
	)
	generic_build_cmd = SubCmd.finish(
		Cli.map(
			Param.str({
				name: "name",
				help: "The artifact to build.",
				default: NoDefault,
			}),
			|name| Build(name),
		),
		{
			name: "build",
			description: "Build a sandboxed artifact and its dependencies",
			mapper: |c| c,
		},
	)
	workflow_cmd = SubCmd.finish(
		Cli.map(
			Param.str({ name: "name", help: "The ordered workflow to execute.", default: NoDefault }),
			|name| Workflow(name),
		),
		{ name: "workflow", description: "Execute an ordered task/build workflow", mapper: |c| c },
	)
	build_cmd = match loaded {
		Ok(spec) if !spec.builds.is_empty() => SubCmd.finish(
			SubCmd.required(
				spec.builds.map(
					|build| SubCmd.empty({
						name: build.name,
						description: "${build.output} [${build.environment}]",
						value: Build(build.name),
					}),
				),
			),
			{
				name: "build",
				description: "Build a sandboxed artifact and its dependencies",
				mapper: |c| c,
			},
		)
		_ => generic_build_cmd
	}
	{ shell_cmd, run_cmd, about } =
		match loaded {
			Ok(spec) => {
				# Weaver rejects an empty subcommand list, so fall back to the
				# generic parsers when there are no shells or tasks.
				shell_cmd: if spec.shells.is_empty()
					generic_shell_cmd
				else
					SubCmd.finish(
						Cli.map(SubCmd.optional(spec.shells.map(shell_choice)), |picked| Shell(picked ?? "default")),
						{ name: "shell", description: "Generate, then enter a dev shell (default: \"default\")", mapper: |c| c },
					),
				run_cmd: if spec.tasks.is_empty()
					generic_run_cmd
				else
					SubCmd.finish(
						SubCmd.required(spec.tasks.map(task_choice)),
						{ name: "run", description: "Generate, then run a task in its shell", mapper: |r| Run(r) },
					),
				about: summary(spec),
			}

			Err(err) => {
				shell_cmd: generic_shell_cmd,
				run_cmd: generic_run_cmd,
				about: match err {
					NoBlueprint => "There is no Blueprint.roc in this directory."
					_ => "Blueprint.roc could not be loaded, so its shells and tasks aren't listed; run `blueprint check` for details."
				},
			}
		}

	Cli.assert_valid(
		Cli.finish(
			SubCmd.optional([
				SubCmd.empty({
					name: "gen",
					description: "Generate from the authoritative lock (the default)",
					value: Gen,
				}),
				shell_cmd,
				run_cmd,
				build_cmd,
				workflow_cmd,
				SubCmd.empty({ name: "tasks", description: "List the tasks", value: Tasks }),
				SubCmd.empty({ name: "update", description: "Update Blueprint.lock to the latest inputs", value: Update }),
				SubCmd.empty({ name: "check", description: "Validate Blueprint.roc", value: Check }),
				SubCmd.empty({ name: "spec", description: "Print the Spec", value: PrintSpec }),
				SubCmd.empty({ name: "flake", description: "Print the generated files", value: PrintFlake }),
			]),
			{
				name: "blueprint",
				version,
				authors: [],
				description: "Turn a Blueprint.roc into Nix environments and artifacts. "
					.concat("Run update to initialize pins. ")
					.concat("Set ROC to choose the roc compiler (default: roc).")
					.concat("\n\n${about}"),
				text_style: Color,
			},
		),
	)
}

summary : Spec -> Str
summary = |spec| {
	count = |n, one, many| if n == 1 "1 ${one}" else "${n.to_str()} ${many}"
	shells = spec.shells.map(|s| s.name)
	tasks = spec.tasks.map(|t| t.name)
	task_part = if tasks.is_empty() "no tasks" else "${count(tasks.len(), "task", "tasks")} (${Str.join_with(tasks, ", ")})"
	"${spec.name}: ${count(shells.len(), "shell", "shells")} (${Str.join_with(shells, ", ")}), ${task_part}."
}

shell_choice : Spec.Shell -> SubCmd.SubcommandParserConfig(Str)
shell_choice = |shell| {
	SubCmd.empty({ name: shell.name, description: "Environment ${shell.environment}", value: shell.name })
}

task_choice : Spec.Task -> SubCmd.SubcommandParserConfig({ task : Str, args : List(Str) })
task_choice = |task|
	SubCmd.finish(
		Param.str_list({ name: "args", help: "Extra arguments appended to the command; put them after --." }),
		{
			name: task.name,
			description: "${Str.join_with(task.run, " ")}  [${task.environment}]",
			mapper: |args| { task: task.name, args },
		},
	)

main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |raw_args| {
	context = context!()
	loaded = match context {
		Ok(ctx) => evaluate!(ctx.layout.project_root)
		Err(err) => Err(err)
	}
	# basic-cli supplies arguments without the executable name.
	match Cli.parse_or_display_message(cli_for(loaded), raw_args, OsStr.to_raw) {
		Err(Help(message)) | Err(Version(message)) => Stdout.line!(message).map_err(|_| Exit(1))
		Err(InvalidUsage(message)) => {
			_ = Stderr.line!(message)
			Err(Exit(2))
		}
		Ok(command) =>
			match run!(command ?? Gen, loaded, context) {
				Ok({}) => Ok({})
				Err(err) => {
					_ = Stderr.line!("blueprint: ${describe(err)}")
					Err(Exit(1))
				}
			}
		}
}

run! = |command, loaded, context| {
	ctx = context?
	match command {
		Check => check!(loaded, ctx.layout.project_root)
		_ => {
			spec = loaded?
			match command {
				Gen => realise!(spec, Request.Generate, ctx)
				Shell(name) => realise!(spec, Request.Shell(name), ctx)
				Run({ task, args }) => realise!(spec, Request.Run(task, args), ctx)
				Build(name) => realise!(spec, Request.Build(name), ctx)
				Workflow(name) => realise!(spec, Request.Workflow(name), ctx)
				Tasks => list_tasks!(spec)
				Update => resolve!(spec, ctx)
				PrintSpec => Stdout.write!(spec.to_str())
				PrintFlake => print_files!(spec)
				Check => check!(loaded, ctx.layout.project_root)
			}
		}
	}
}

## Type-check Blueprint.roc (including whole-config validation), then reuse
## the Spec loaded for CLI parsing to check provider compatibility. This also
## preserves validation for older platforms that only lower at run time.
check! : Try(Spec, _), Str => Try({}, _)
check! = |loaded, root| {
	check_host!()?
	Cmd.new_str(roc!()?).args_str(["check", "Blueprint.roc"])
		.cwd(path(root)).exec_cmd!()
		.map_err(|err| CompilerFailed(Str.inspect(err)))?
	_ = render(loaded?)?
	Stdout.line!("Blueprint.roc is valid")
}

## Compile and run Blueprint.roc, then parse the Spec it prints.
evaluate! : Str => Try(Spec, _)
evaluate! = |root| {
	if !(path("${root}/Blueprint.roc").exists!() ?? False) {
		return Err(NoBlueprint)
	}
	check_host!()?
	output = Cmd.new_str(roc!()?).args_str(["Blueprint.roc"])
		.cwd(path(root)).exec_output!()
		.map_err(|err| CompilerFailed(Str.inspect(err)))?
	spec = Spec.parse(output.stdout_utf8).map_err(|err| BadSpec(err))?
	missing = spec.unsupported_features(provider.features)
	if !missing.is_empty() {
		return Err(NeedsFeatures(missing))
	}
	Project.validate(spec).map_err(|message| InvalidProject(message))
}

render : Spec -> Try(List(Provider.File), _)
render = |spec| (provider.render)(spec).map_err(|msg| RenderFailed(msg))

## Run an argv from the provider.
exec! : List(Str), Str => Try({}, _)
exec! = |argv, root|
	match argv {
		[program, .. as args] =>
			Cmd.new_str(program)
				.args_str(args)
				.cwd(path(root))
				.exec_cmd!()
				.map_err(
					|err|
						match err {
							ExecCmdFailed({ exit_code, .. }) => CommandFailed(argv, exit_code)
							other => other
						},
				)

		[] => Ok({})
	}

print_files! : Spec => Try({}, _)
print_files! = |spec| {
	files = render(spec)?
	match files {
		[only] => Stdout.write!(only.contents)
		_ => {
			for file in files {
				Stdout.write!("# ${file.path}\n${file.contents}")?
			}
			Ok({})
		}
	}
}

## Probe identity before evaluating config with the selected compiler.
## A relative ROC executable belongs to the invocation directory, not root.
roc! : () => Try(Str, _)
roc! = || {
	override = Env.var_str!("ROC") ?? "roc"
	compiler = if override.contains("/") and !override.starts_with("/") {
		cwd = Env.cwd!()?.to_str()?
		"${cwd}/${override}"
	} else override
	output = Cmd.new_str(compiler).args_str(["version"]).exec_output!()
		.map_err(
			|err| CompilerFailed(
				"could not probe ${compiler}: ${Str.inspect(err)}",
			),
		)?
	expected = "Roc compiler version ${compiler_version.trim()}"
	if output.stdout_utf8.trim() != expected {
		return Err(
			CompilerFailed(
				"incompatible ROC executable ${compiler}: "
					.concat("expected ${expected}; got ${output.stdout_utf8.trim()}"),
			),
		)
	}
	Ok(compiler)
}

Context : { layout : Layout, target : Str }

## Caller paths are observations, resolved once against the selected root.
context! : () => Try(Context, _)
context! = || {
	cwd = Env.cwd!()?.to_str()?
	root = path(resolve(cwd, Env.var_str!("BLUEPRINT_ROOT") ?? cwd))
		.canonicalize!()?.to_str()?
	workspace = normalize(
		resolve(
			root,
			Env.var_str!("BLUEPRINT_WORKSPACE") ?? ".blueprint",
		),
	)
	generated = normalize(
		resolve(
			root,
			Env.var_str!("BLUEPRINT_GENERATED_ROOT") ?? workspace,
		),
	)
	lock = normalize(
		resolve(
			root,
			Env.var_str!("BLUEPRINT_LOCK") ?? "Blueprint.lock",
		),
	)
	Ok({
		layout: Layout.{
			project_root: root,
			workspace,
			generated_root: generated,
			lock_path: lock,
		},
		target: Env.var_str!("BLUEPRINT_TARGET") ?? "x86_64-linux",
	})
}

## Config-platform execution currently has only a verified Linux host.
check_host! : () => Try({}, [UnsupportedHost])
check_host! = ||
	match Env.platform!() {
		{ arch: X64, os: LINUX } => Ok({})
		_ => Err(UnsupportedHost)
	}

resolve : Str, Str -> Str
resolve = |root, value| if value.starts_with("/") value else "${root}/${value}"

## Lexical normalization is separate from the runtime no-symlink check.
normalize : Str -> Str
normalize = |value| {
	parts = value.split_on("/").fold(
		[],
		|acc, part|
			match part {
				"" | "." => acc
				".." => acc.drop_last(1)
				_ => acc.append(part)
			},
	)
	"/${Str.join_with(parts, "/")}"
}

## Relative caller locations use the project root, not generated nesting.
expect resolve("/project", "cache/nix") == "/project/cache/nix"

## An out-of-tree caller location remains independent of the project root.
expect resolve("/project", "/tmp/cache") == "/tmp/cache"

## Equivalent lexical locations normalize before filesystem safety checks.
expect normalize("/project/a/.././.blueprint/") == "/project/.blueprint"

parent : Str -> Str
parent = |value| {
	parts = value.split_on("/").drop_last(1)
	result = Str.join_with(parts, "/")
	if result.is_empty() "/" else result
}

## Refuse destination/source aliases before touching caller-owned files.
safe_path! : Str => Try({}, _)
safe_path! = |value| {
	if !value.starts_with("/") or normalize(value) != value {
		return Err(UnsafePath(value))
	}
	if path(value).is_sym_link!()? {
		return Err(UnsafePath(value))
	}
	if value != "/" {
		safe_path!(parent(value))?
	}
	Ok({})
}

## Local pins may not smuggle host files into Nix through symbolic links.
safe_source! : Str => Try({}, _)
safe_source! = |value| {
	safe_path!(value)?
	match path(value).type!()? {
		IsDir => {
			for child in path(value).list!()? {
				safe_source!(child.to_str()?)?
			}
			Ok({})
		}
		IsFile => Ok({})
		_ => Err(UnsafePath(value))
	}
}

## The pure planner validates the entire request before any staging effects.
realise! : Spec, Request, Context => Try({}, _)
realise! = |spec, request, ctx| {
	layout = ctx.layout
	_ = (provider.preflight)(spec, request, ctx.target, layout)
		.map_err(|message| RenderFailed(message))?
	if !(path(layout.lock_path).exists!()?) {
		return Err(LockFailed("missing authoritative lock; run `blueprint update`"))
	}
	safe_path!(layout.lock_path)?
	if path(layout.lock_path).type!()? != IsFile {
		return Err(UnsafePath(layout.lock_path))
	}
	lock = Lock.parse(path(layout.lock_path).read_utf8!()?)
		.map_err(|_| LockFailed("unsupported Blueprint lock format; run blueprint update"))?
	lock.stale(spec).map_err(|message| LockFailed(message))?
	steps = (provider.realise)(spec, request, ctx.target, layout, lock)
		.map_err(
			|err|
				match err {
					InvalidLock(message) => LockFailed(message)
					Unrealisable(message) => RenderFailed(message)
				},
		)?
	for step in steps.steps {
		execute_step!(step, layout)?
	}
	Ok({})
}

## One consumer-owned executor for standalone requests and workflow steps.
## All planning has succeeded before the first materialization or task effect.
execute_step! : Steps.Step, Layout => Try({}, _)
execute_step! = |step, layout| {
	for operation in step.operations {
		match operation {
			VerifyLocal({ path: local, nar_hash }) => {
				safe_source!(local)?
				observed = Cmd.new_str("nix").args_str(["hash", "path", "--sri", local])
					.cwd(path(layout.project_root)).exec_output!()?
				Stderr.write!(observed.stderr_utf8_lossy)?
				if observed.stdout_utf8.trim() != nar_hash {
					return Err(
						LockFailed(
							"local source ${local} changed; run `blueprint update`",
						),
					)
				}
			}
			Snapshot({ root, destination, exclude }) => {
				safe_path!(destination)?
				exec!(
					["python3", "-I", "-c", snapshot_helper, root, destination]
						.concat(exclude),
					layout.project_root,
				)?
			}
		}
	}
	stage!(step.files, layout)?
	match step.action {
		Build(name) => report_build!(step, name, layout.project_root)
		_ => exec!(step.argv, layout.project_root).map_err(
			|err|
				match (step.action, err) {
					(Run(name), CommandFailed(_, code)) => TaskFailed(name, code)
					_ => err
				},
		)
	}
}

## Resolve the selected installable with the exact planned build command.
## Dependency metadata stays descriptive; no store paths are guessed for it.
report_build! : Steps.Step, Str, Str => Try({}, _)
report_build! = |plan, name, root| {
	for artifact in plan.artifacts {
		Stderr.line!(
			"building ${artifact.name}: ${artifact.installable} "
				.concat("(output ${artifact.output})"),
		)?
	}
	artifact = plan.artifacts.find_first(|item| item.name == name)
		.map_err(|_| RenderFailed("build plan is missing artifact ${name}"))?
	match plan.argv {
		[program, .. as args] => {
			result = Cmd.new_str(program).args_str(args).cwd(path(root))
				.stderr(Inherit).exec_output!()?
			Stdout.write!(result.stdout_utf8)?
			Stderr.line!(
				"built ${artifact.name}: ${artifact.installable} -> "
					.concat(result.stdout_utf8.trim()),
			)
		}
		[] => Err(RenderFailed("build plan has no command"))
	}
}

## Plans are compiled-in data, but filesystem aliases remain runtime state.
stage! : List(Steps.File), Layout => Try({}, _)
stage! = |files, layout| {
	safe_path!(layout.generated_root)?
	for file in files {
		if !file.path.starts_with("${layout.generated_root}/")
			or file.path == layout.lock_path {
			return Err(UnsafePath(file.path))
		}
		safe_path!(file.path)?
	}
	for file in files {
		path(parent(file.path)).create_all!()?
		atomic_write!(file.path, file.contents)?
	}
	Ok({})
}

list_tasks! : Spec => Try({}, _)
list_tasks! = |spec| {
	lines = spec.tasks.map(|t| "${t.name}\t(${t.environment})\t${Str.join_with(t.run, " ")}")
	Stdout.line!(Str.join_with(lines, "\n"))
}

## Explicit update alone resolves pins and atomically publishes the authority.
resolve! : Spec, Context => Try({}, _)
resolve! = |spec, ctx| {
	layout = ctx.layout
	resolution = (provider.resolve)(spec, ctx.target, layout)
		.map_err(|message| RenderFailed(message))?
	safe_path!(layout.lock_path)?
	observed = Cmd.new_str("python3")
		.args_str([
			"-I",
			"-c",
			snapshot_helper,
			"authority-token",
			layout.lock_path,
		])
		.cwd(path(layout.project_root)).exec_output!()?
	prior = observed.stdout_utf8.trim()
	# Reject ancestor escapes and nested symlinks before staging or fetching.
	for local in resolution.locals {
		safe_source!(local)?
	}
	native_lock = resolution.native_lock
	safe_path!(native_lock)?
	if native_lock == layout.lock_path or !native_lock.starts_with("${layout.generated_root}/") {
		return Err(UnsafePath(native_lock))
	}
	stage!(resolution.files, layout)?
	# Derived state is disposable. Unlink it rather than letting the provider
	# follow a stale hard-link alias while explicitly resolving fresh pins.
	if path(native_lock).exists!()? {
		path(native_lock).delete!()?
	}
	exec!(resolution.argv, layout.project_root)?
	safe_path!(native_lock)?
	resolved = (provider.lock_from_native)(spec, layout, path(native_lock).read_utf8!()?)
		.map_err(|message| LockFailed(message))?
	lock = { ..resolved, intent: Lock.intent_of(spec) }
	path(parent(layout.lock_path)).create_all!()?
	publish_authority!(
		layout.lock_path,
		prior,
		lock.to_str(),
		layout.project_root,
	)
}

## A short-lived helper holds the writer lock across comparison and rename.
## Competing updates with distinct generated roots cannot roll back authority.
publish_authority! : Str, Str, Str, Str => Try({}, _)
publish_authority! = |destination, prior, contents, root| {
	temporary = Env.create_temp_dir_in!(
		path(parent(destination)),
		".blueprint-write-",
	)?
	publish! = || {
		staged = temporary.join("file")
		staged.write_utf8!(contents)?
		exec!(
			[
				"python3",
				"-I",
				"-c",
				snapshot_helper,
				"authority-publish",
				destination,
				prior,
				staged.to_str()?,
			],
			root,
		)
	}
	result = publish!()
	_ = temporary.delete_all!()
	result
}

## Rename publication avoids truncation and overwriting hard-linked contents.
atomic_write! : Str, Str => Try({}, _)
atomic_write! = |destination, contents| {
	temporary = Env.create_temp_dir_in!(
		path(parent(destination)),
		".blueprint-write-",
	)?
	publish! = || {
		staged = temporary.join("file")
		staged.write_utf8!(contents)?
		safe_path!(destination)?
		staged.rename!(path(destination))
	}
	result = publish!()
	_ = temporary.delete_all!()
	result
}

path : Str -> Path
path = |p| Path.from_os_str(OsStr.from_str(p))

describe : _ -> Str
describe = |err|
	match err {
		NoBlueprint => "there is no Blueprint.roc in the selected project root"
		UnsupportedHost =>
			"Blueprint.roc execution currently requires x86_64 Linux; "
				.concat("Systems/BLUEPRINT_TARGET describe outputs, ")
				.concat("not compiler host support")
		CompilerFailed(message) =>
			"could not execute the configuration compiler; "
				.concat("install Roc ${compiler_version.trim()} or set ROC to its ")
				.concat("executable (the Nix package supplies it):\n${message}")
		LockFailed(message) => "${message}; use `blueprint update` to initialize "
			.concat("or deliberately refresh pins")
		UnsafePath(value) => "refusing unsafe or symlinked runtime path: ${value}"
		BadSpec(InvalidSexpr(msg)) => "could not read the Spec from Blueprint.roc: ${msg}"
		BadSpec(UnsupportedFormat({ major, minor })) => "Spec format ${U64.to_str(major)}.${U64.to_str(minor)} is not supported by this blueprint (understands major ${Spec.current_format.major.to_str()}); upgrade blueprint or change the platform version"
		NeedsFeatures(missing) => "Blueprint.roc needs features: ${Str.join_with(missing, ", ")}; upgrade blueprint"
		InvalidProject(msg) => "invalid Spec project: ${msg}"
		RenderFailed(msg) => "cannot generate the ${provider.name} files: ${msg}"
		BadSpec(MissingRequiredField("format")) => "Blueprint.roc uses an older roc-blueprint platform that this blueprint can't read; update the platform URL in its app header to a current release"
		BadSpec(MissingRequiredField(field)) => "the Spec from Blueprint.roc is missing ${field}"
		NonZeroExitCode({ command, exit_code, stderr_utf8_lossy, .. }) =>
			"`${command}` exited with code ${I32.to_str(exit_code)}:\n"
				.concat(stderr_utf8_lossy)
		TaskFailed(name, code) => "task ${name} exited with code ${code.to_str()}"
		UnknownTask(name, known) => "no task named \"${name}\"; Blueprint.roc defines: ${Str.join_with(known, ", ")}"
		UnknownShell(name, known) => "no shell named \"${name}\"; Blueprint.roc defines: ${Str.join_with(known, ", ")}"
		ExecFailed({ command, exit_code }) => "`${command}` exited with code ${I32.to_str(exit_code)}"
		CommandFailed(argv, code) => "`${Str.join_with(argv, " ")}` exited with code ${code.to_str()}"
		ExecCmdFailed({ command, exit_code }) => "`${command}` exited with code ${exit_code.to_str()}"
		other => Str.inspect(other)
	}
