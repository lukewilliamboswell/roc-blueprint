## `blueprint`: turns a `Blueprint.roc` into a working Nix environment.
##
## The Roc compiler validates `Blueprint.roc` and prints the blueprint Spec;
## this CLI consumes pure plans and owns file/process effects. Only explicit
## update publishes the authority; ordinary operations use its resolved pins.
app [main!] {
	core: "../blueprint-core/main.roc",
	http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	nix: "../blueprint-nix/main.roc",
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc2/Gj3zVDr3qrQa6aTh7Z1zgUfe9NeBE6R76T5ho3xrc8af.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.9.0/7j6KBFBEZ8pNMLQHkx9xiwyZ2PmwQPgKNDPUih6gKe77.tar.zst",
}

import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path
import pf.Stdout
import pf.Stderr
import weaver.Cli
import weaver.Opt
import weaver.Param
import weaver.SubCmd
import core.Spec
import core.Project
import core.Request
import core.Steps
import core.Layout
import core.Provider
import core.Realise
import core.Lock
import core.Tree
import Bootstrap
import Download
import Paths
import Published
import Store
import nix.NixProvider
import "compiler-version" as compiler_version : Str

version : Str
version = "0.6.0-rc1"

## The providers a request may be planned with. This is the only reference to
## a concrete provider: everything else uses the Provider contract
## (docs/architecture.adoc, invariant 7; checked by scripts/test.roc). Which
## of them a request needs is not chosen here or by the caller's environment:
## `Realise.plan` asks one only for an environment that has a tool from a
## source it supplies.
providers : List(Provider)
providers = [NixProvider.provider]

## The providers by name, for a message.
provider_names : Str
provider_names = Str.join_with(providers.map(|provider| provider.name), ", ")

Command : [
	Gen,
	Shell(Str),
	Run({ task : Str, args : List(Str) }),
	Build(Str),
	Workflow(Str),
	Tasks,
	Update(List(Str)),
	Requirements({ json : Bool, tasks : List(Str) }),
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
		{ name: "shell", description: "Enter a shell's environment", mapper: |c| c },
	)
	generic_run_cmd = SubCmd.finish(
		{
			task: Param.str({ name: "task", help: "The task to run.", default: NoDefault }),
			args: Param.str_list({ name: "args", help: "Extra arguments for the task; put them after --." }),
		}.Cli,
		{ name: "run", description: "Run a task in its environment", mapper: |r| Run(r) },
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
	update_cmd = SubCmd.finish(
		Cli.map(
			Param.str_list({ name: "names", help: "Inputs and fetched programs to update, by name; all of them when none is given." }),
			|names| Update(names),
		),
		{ name: "update", description: "Update Blueprint.lock: the latest inputs, and the digests of fetched programs", mapper: |c| c },
	)
	requirements_cmd = SubCmd.finish(
		{
			json: Opt.flag({ short: "", long: "json", help: "Print the report as JSON, for a program to read." }),
			tasks: Param.str_list({ name: "tasks", help: "The tasks to report on; every task when none is given." }),
		}.Cli,
		{ name: "requirements", description: "Say what tasks need: a provider, fetched programs, tools of the machine", mapper: |r| Requirements(r) },
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
						{ name: "shell", description: "Enter a shell's environment (default: \"default\")", mapper: |c| c },
					),
				run_cmd: if spec.tasks.is_empty()
					generic_run_cmd
				else
					SubCmd.finish(
						SubCmd.required(spec.tasks.map(task_choice)),
						{ name: "run", description: "Run a task in its environment", mapper: |r| Run(r) },
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
					description: "Generate the Nix files from the lock (the default)",
					value: Gen,
				}),
				shell_cmd,
				run_cmd,
				build_cmd,
				workflow_cmd,
				SubCmd.empty({ name: "tasks", description: "List the tasks", value: Tasks }),
				update_cmd,
				requirements_cmd,
				SubCmd.empty({ name: "check", description: "Validate Blueprint.roc", value: Check }),
				SubCmd.empty({ name: "spec", description: "Print the Spec", value: PrintSpec }),
				SubCmd.empty({ name: "flake", description: "Print the generated files", value: PrintFlake }),
			]),
			{
				name: "blueprint",
				version,
				authors: [],
				description: "Carry out a Blueprint.roc: its environments, tasks, builds and workflows. "
					.concat("Run update to write Blueprint.lock. ")
					.concat("Set ROC to choose the Roc compiler.")
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
	# A sandboxed build runs this executable as its builder. There is no
	# Blueprint.roc or compiler there, so dispatch before loading either.
	match raw_args {
		[first, .. as rest] if first.to_bytes() == "__build-runner".to_utf8() => return build_runner!(rest)
		_ => {}
	}
	context = context!()
	loaded = match context {
		Ok(ctx) => evaluate!(ctx)
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
					_ = Stderr.line!("blueprint: ${describe(err, provider_names)}")
					Err(Exit(1))
				}
			}
	}
}

run! = |command, loaded, context| {
	ctx = context?
	match command {
		Check => check!(loaded, ctx)
		_ => {
			spec = loaded?
			match command {
				Gen => realise!(spec, Request.Generate, ctx)
				Shell(name) => realise!(spec, Request.Shell(name), ctx)
				Run({ task, args }) => realise!(spec, Request.Run(task, args), ctx)
				Build(name) => realise!(spec, Request.Build(name), ctx)
				Workflow(name) => realise!(spec, Request.Workflow(name), ctx)
				Tasks => list_tasks!(spec)
				Update(names) => resolve!(spec, names, ctx)
				Requirements({ json, tasks }) => report_requirements!(spec, json, tasks, ctx)
				PrintSpec => Stdout.write!(spec.to_str())
				PrintFlake => print_files!(spec)
				Check => check!(loaded, ctx)
			}
		}
	}
}

## Type-check Blueprint.roc (including whole-config validation), then reuse
## the Spec loaded for CLI parsing to check provider compatibility. This also
## preserves validation for older platforms that only lower at run time.
check! : Try(Spec, _), Context => Try({}, _)
check! = |loaded, ctx| {
	check_host!()?
	Cmd.new(OsStr.from_str(roc!(ctx)?)).args(["check", "Blueprint.roc"].map(OsStr.from_str))
		.cwd(path(ctx.layout.project_root)).exec!()
		.map_err(|err| CompilerFailed(Str.inspect(err)))?
	_ = rendered(loaded?)?
	Stdout.line!("Blueprint.roc is valid")
}

## Compile and run Blueprint.roc, then parse the Spec it prints.
evaluate! : Context => Try(Spec, _)
evaluate! = |ctx| {
	root = ctx.layout.project_root
	if !(path("${root}/Blueprint.roc").exists!() ?? False) {
		return Err(NoBlueprint)
	}
	check_host!()?
	output = Cmd.new(OsStr.from_str(roc!(ctx)?)).args(["Blueprint.roc"].map(OsStr.from_str))
		.cwd(path(root)).capture!()
		.map_err(|err| CompilerFailed(Str.inspect(err)))?
	spec = Spec.parse(output).map_err(|err| BadSpec(err))?
	current_platform(spec)?
	missing = spec.unsupported_features(providers.fold(Realise.features, |all, provider| all.concat(provider.features)))
	if !missing.is_empty() {
		return Err(NeedsFeatures(missing))
	}
	Project.validate(spec).map_err(|message| InvalidProject(message))
}

## A Spec from a platform older than 0.6.0 does not say that its sources are
## all declared: its tools may name a source that platform implied, which
## nothing here supplies. It is refused as that, before anything in it is
## read as if it were complete.
current_platform : Spec -> Try({}, [OldPlatform])
current_platform = |spec| if spec.requires_.contains("explicit-sources") Ok({}) else Err(OldPlatform)

expect current_platform({ ..Spec.empty("x"), requires_: ["explicit-sources", "programs"] }) == Ok({})
expect current_platform(Spec.empty("x")) == Err(OldPlatform) and current_platform({ ..Spec.empty("x"), requires_: ["sources", "builds"] }) == Err(OldPlatform)

## The files every provider would generate for the Spec.
rendered : Spec -> Try(List(Provider.File), _)
rendered = |spec| {
	var $files = []
	for provider in providers {
		$files = $files.concat((provider.render)(spec).map_err(|msg| RenderFailed(msg))?)
	}
	Ok($files)
}

## Run an argv from the provider.
exec! : List(Str), Str => Try({}, _)
exec! = |argv, root|
	match argv {
		[program, .. as args] =>
			Cmd.new(OsStr.from_str(program))
				.args(args.map(OsStr.from_str))
				.cwd(path(root))
				.exec!()
				.map_err(
					|err|
						match err {
							BadExitStatus(Cmd.Output.{ status: Exited(code), .. }) => CommandFailed(argv, code)
							BadExitStatus(Cmd.Output.{ status: Signaled(signal), .. }) => CommandFailed(argv, 128 + signal)
							other => other
						},
				)

		[] => Ok({})
	}

## Run a step's argv with its directories ahead of the caller's PATH, so that
## the argv and whatever it starts find the programs there first.
exec_within! : List(Str), Str, List(Str) => Try({}, _)
exec_within! = |argv, root, directories| {
	if directories.is_empty() {
		return exec!(argv, root)
	}
	existing = match Env.var!(OsStr.from_str("PATH")) {
		Ok(value) => value.to_str_try().map_err(|_| Refused("PATH is not text, so nothing can be put ahead of it"))?
		Err(_) => ""
	}
	search = Paths.search(directories, existing)
		.map_err(|Unsearchable(directory)| Refused("${directory} cannot be an entry of PATH"))?
	match argv {
		[program, .. as args] =>
			Cmd.new(OsStr.from_str(program))
				.args(args.map(OsStr.from_str))
				.cwd(path(root))
				.env(OsStr.from_str("PATH"), OsStr.from_str(search))
				.exec!()
				.map_err(
					|err|
						match err {
							BadExitStatus(Cmd.Output.{ status: Exited(code), .. }) => CommandFailed(argv, code)
							BadExitStatus(Cmd.Output.{ status: Signaled(signal), .. }) => CommandFailed(argv, 128 + signal)
							other => other
						},
				)

		[] => Ok({})
	}
}

print_files! : Spec => Try({}, _)
print_files! = |spec| {
	files = rendered(spec)?
	match files {
		# Stdout stays empty, so that what reads it reads no file.
		[] => Stderr.line!("blueprint: nothing is generated for this project: it declares no source that ${provider_names} supplies")
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
## An explicit ROC must be the compatible compiler. Otherwise a compatible
## `roc` on PATH is used, and failing that the release this executable records
## a download of is kept in the store, by its digest. No provider is asked:
## reading a Blueprint.roc needs none installed.
roc! : Context => Try(Str, _)
roc! = |_ctx| {
	expected = "Roc compiler version ${compiler_version.trim()}"
	match Env.var_str!("ROC") {
		Ok(override) => {
			compiler = if override.contains("/") and !override.starts_with("/") {
				cwd = Env.cwd!()?.to_str()?
				"${cwd}/${override}"
			} else override
			output = Cmd.new(OsStr.from_str(compiler)).args(["version"].map(OsStr.from_str)).capture!()
				.map_err(
					|err| CompilerFailed(
						"could not probe ${compiler}: ${Str.inspect(err)}",
					),
				)?
			if output.trim() != expected {
				return Err(
					CompilerFailed(
						"incompatible ROC executable ${compiler}: "
							.concat("expected ${expected}; got ${output.trim()}"),
					),
				)
			}
			Ok(compiler)
		}
		Err(_) => {
			on_path = Cmd.new(OsStr.from_str("roc")).args(["version"].map(OsStr.from_str)).capture!()
				.map_ok(|output| output.trim() == expected) ?? False
			if on_path {
				return Ok("roc")
			}
			tag = compiler_version.trim()
			system = host_system!()?
			program = Bootstrap.compiler(tag, system)
				.map_err(|_| CompilerFailed("this blueprint records no download of Roc ${tag} for ${system}"))?
			store = Store.root!().map_err(|message| CompilerFailed("could not fetch Roc ${tag}: ${message}"))?
			Store.program!(store, program, BuiltIn).map_err(|message| CompilerFailed("could not fetch Roc ${tag}: ${message}"))
		}
	}
}

Context : { layout : Layout, target : Str }

## Caller paths are observations, resolved once against the selected root.
context! : () => Try(Context, _)
context! = || {
	# Windows reports `\\?\D:\project`; hold `D:/project` (see Paths).
	cwd = Paths.portable(Env.cwd!()?.to_str()?)
	root = Paths.portable(
		path(Paths.resolve(cwd, Env.var_str!("BLUEPRINT_ROOT") ?? cwd))
			.canonicalize!()?.to_str()?,
	)
	workspace = Paths.normalize(
		Paths.resolve(
			root,
			Env.var_str!("BLUEPRINT_WORKSPACE") ?? ".blueprint",
		),
	)
	generated = Paths.normalize(
		Paths.resolve(
			root,
			Env.var_str!("BLUEPRINT_GENERATED_ROOT") ?? workspace,
		),
	)
	lock = Paths.normalize(
		Paths.resolve(
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
		target: Env.var_str!("BLUEPRINT_TARGET") ?? host_target!(),
	})
}

## The System a machine is, when `blueprint` runs on it: the three a binary is
## released for, and x86_64 Windows, where tasks that need no provider run.
## Intel macOS is not one: current nixpkgs has dropped that
## system, so no environment could be entered there. `x86_64-darwin` remains
## a System a configuration may declare.
supported_host : _ -> Try(Str, [UnsupportedHost])
supported_host = |machine|
	match machine {
		{ arch: X64, os: LINUX } => Ok("x86_64-linux")
		{ arch: AARCH64, os: LINUX } => Ok("aarch64-linux")
		{ arch: AARCH64, os: MACOS } => Ok("aarch64-darwin")
		{ arch: X64, os: WINDOWS } => Ok("x86_64-windows")
		_ => Err(UnsupportedHost)
	}

expect supported_host({ arch: X64, os: LINUX }) == Ok("x86_64-linux")
expect supported_host({ arch: AARCH64, os: LINUX }) == Ok("aarch64-linux")
expect supported_host({ arch: AARCH64, os: MACOS }) == Ok("aarch64-darwin")
expect supported_host({ arch: X64, os: MACOS }) == Err(UnsupportedHost)
expect supported_host({ arch: X64, os: WINDOWS }) == Ok("x86_64-windows")
expect supported_host({ arch: AARCH64, os: WINDOWS }) == Err(UnsupportedHost)

check_host! : () => Try({}, [UnsupportedHost])
check_host! = || {
	_ = host_system!()?
	Ok({})
}

## The System this machine realises by default. Unsupported hosts fall back
## to the Linux default and fail later in check_host!.
host_target! : () => Str
host_target! = || host_system!() ?? "x86_64-linux"

## The System this executable itself runs on.
host_system! : () => Try(Str, [UnsupportedHost])
host_system! = || supported_host(Env.platform!())

## A build runs this executable as its builder, so it must be built for the
## System the build runs on.
runner_host : Try(Str, [UnsupportedHost]), Str -> Try({}, _)
runner_host = |host, system|
	if host == Ok(system) {
		Ok({})
	} else {
		Err(
			Refused(
				"sandboxed builds run blueprint itself as their builder, so "
					.concat("blueprint must run on ${system}; this host is ")
					.concat(host ?? "unsupported"),
			),
		)
	}

expect runner_host(Ok("x86_64-linux"), "x86_64-linux") == Ok({})
expect
	[Ok("aarch64-linux"), Ok("x86_64-darwin"), Ok("aarch64-darwin"), Err(UnsupportedHost)].all(
		|host| runner_host(host, "x86_64-linux").is_err(),
	)

## A path a provider can place in generated text without inspecting it.
plain_path : Str -> Bool
plain_path = |value|
	value.starts_with("/")
		and Paths.normalize(value) == value
			and !value.to_utf8().any(
				|byte| byte < 32 or byte == 127 or byte == '"' or byte == '\\' or byte == '$',
			)

expect plain_path("/nix/store/abc-blueprint/bin/.blueprint-wrapped")
expect plain_path("/home/user name/bin/blueprint")
expect
	["blueprint", "/a/../b", "/a\"b", "/a\\b", "/a\${b}", "/a\nb", ""].all(
		|value| !plain_path(value),
	)

## This executable's own path, for a build that runs on `system`.
runner_executable! : Str => Try(Str, _)
runner_executable! = |system| {
	runner_host(host_system!(), system)?
	executable = Env.exe_path!()
		.map_err(|_| Refused("cannot locate the blueprint executable to run builds"))?
	text = executable.to_str()
		.map_err(|_| Refused("blueprint cannot run builds from ${executable.display()}"))?
	if !plain_path(text) {
		return Err(Refused("blueprint cannot run builds from ${text}"))
	}
	Ok(text)
}

## Refuse destination/source aliases before touching caller-owned files.
safe_path! : Str => Try({}, _)
safe_path! = |value| {
	if !Paths.absolute(value) or Paths.normalize(value) != value {
		return Err(UnsafePath(value))
	}
	if path(value).is_sym_link!()? {
		return Err(UnsafePath(value))
	}
	if Paths.parent(value) != value {
		safe_path!(Paths.parent(value))?
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

## Blueprint's content digest of a local source tree (see core `Tree`). Each
## file is streamed through the builtin SHA-256 hasher in bounded chunks, so
## no file is held in memory whole, and no provider tool is involved.
tree_digest! : Str => Try(Str, _)
tree_digest! = |root| {
	entries = tree_entries!(root, "")?
	Tree.digest(entries).map_err(|message| LockFailed(message))
}

tree_entries! : Str, Str => Try(List(Tree.Entry), _)
tree_entries! = |root, prefix| {
	var $entries = []
	dir = if prefix == "" root else "${root}/${prefix}"
	for child in path(dir).list!()? {
		full = child.to_str()?
		name = full.split_on("/").last() ?? full
		relative = if prefix == "" name else "${prefix}/${name}"
		match child.type!()? {
			IsDir => {
				$entries = $entries.append({ path: relative, kind: Dir }).concat(tree_entries!(root, relative)?)
			}
			IsFile => {
				executable = child.is_executable!()?
				$entries = $entries.append({ path: relative, kind: File({ executable, digest: Store.file_digest!(full)? }) })
			}
			_ => return Err(UnsafePath(full))
		}
	}
	Ok($entries)
}

## Observe authority bytes without decoding them, including an absent
## authority. The token is `sha256:<hex>` of the raw bytes.
authority_token! : Str => Try(Str, _)
authority_token! = |file| {
	safe_path!(file)?
	if !(path(file).exists!()?) {
		return Ok("absent")
	}
	if path(file).type!()? != IsFile {
		return Err(Refused("authority is not a regular file: ${file}"))
	}
	Ok("sha256:${Store.file_digest!(file)?.to_hex()}")
}

## Lexical containment of normalized absolute paths, as bytes: directory
## entries need not be valid UTF-8.
within : List(U8), List(U8) -> Bool
within = |child, ancestor| {
	base = if ancestor == ['/'] [] else ancestor
	child == ancestor or child.take_first(base.len() + 1) == base.append('/')
}

expect within("/project/work".to_utf8(), "/project".to_utf8())
expect within("/project".to_utf8(), "/project".to_utf8())
expect within("/project".to_utf8(), "/".to_utf8())
expect !within("/project-work".to_utf8(), "/project".to_utf8())
expect !within("/project".to_utf8(), "/project/work".to_utf8())

## A namespace identity as the kernel prints it, e.g. `mnt:[4026531841]`.
valid_namespace : Str, Str -> Bool
valid_namespace = |name, identity| {
	prefix = "${name}:["
	digits = identity.to_utf8().drop_first(prefix.to_utf8().len()).drop_last(1)
	identity.starts_with(prefix)
		and identity.ends_with("]")
			and !digits.is_empty()
				and digits.all(|byte| byte >= '0' and byte <= '9')
}

expect valid_namespace("mnt", "mnt:[4026531841]")
expect valid_namespace("net", "net:[0]")
expect
	["mnt:[]", "mnt:]", "net:[1]", "mnt:[1]\n", "mnt:[1] ", " mnt:[1]", "mnt:[-1]", "mnt:[1a]", "mnt:[1]]", ""].all(
		|identity| !valid_namespace("mnt", identity),
	)

## A child's namespaces are its parent's, so this `readlink` program observes
## the calling process. basic-cli cannot read a link itself.
observe_namespace! : Str, Str => Try(Str, Str)
observe_namespace! = |readlink, name| {
	output = Cmd.new(OsStr.from_str(readlink)).args(["/proc/self/ns/${name}"].map(OsStr.from_str)).capture!()
		.map_err(|_| "could not run readlink")?
	Ok(output.drop_suffix("\n"))
}

namespace! : Str => Try(Str, _)
namespace! = |name| {
	identity = observe_namespace!("readlink", name)
		.map_err(
			|reason|
				Refused(
					"cannot observe caller build isolation; use Linux with "
						.concat("readable /proc/self/ns/${name}: ${reason}"),
				),
		)?
	if !valid_namespace(name, identity) {
		return Err(Refused("invalid caller ${name} namespace identity"))
	}
	Ok(identity)
}

## What the provider's build derivation passes to `blueprint __build-runner`.
## `readlink`, `chmod` and `ln` are absolute programs: a build has no implicit
## PATH. Only a build whose environment has Roc packages names them and `ln`.
BuildSpec : {
	project : Str,
	argv : List(Str),
	output : Str,
	path : Str,
	inputs : Str,
	artifacts : Str,
	readlink : Str,
	chmod : Str,
	roc_packages : Try(List(RocPackage), [Missing]),
	ln : Try(Str, [Missing]),
}

## A released Roc bundle: the content hash Roc looks for in its package cache
## and the directory holding the unpacked bundle.
RocPackage : { name : Str, path : Str }

## The builder of a sandboxed build: exact argv and one contained,
## symlink-free output. The specification is the given file, or the one the
## derivation passes as `blueprintSpecPath`.
build_runner! : List(OsStr) => Try({}, [Exit(I32)])
build_runner! = |args| {
	result = match args {
		[] =>
			match Env.var!(OsStr.from_str("blueprintSpecPath")) {
				Ok(file) => run_build!(Path.from_os_str(file))
				Err(_) => Err(Invalid("missing build specification"))
			}

		[file] => run_build!(Path.from_os_str(file))
		_ => Err(Invalid("expected one build specification"))
	}
	match result {
		Ok({}) => Ok({})
		Err(Exited(code)) => Err(Exit(code))
		Err(Invalid(message)) => {
			_ = Stderr.line!("blueprint build: ${message}")
			Err(Exit(1))
		}
		Err(other) => {
			_ = Stderr.line!("blueprint build: ${Str.inspect(other)}")
			Err(Exit(1))
		}
	}
}

run_build! : Path => Try({}, _)
run_build! = |file| {
	text = file.read_utf8!()?
	# Nothing else, not even reading the rest of the specification, precedes
	# the isolation check.
	require_isolation!(text)?
	parsed : Try(BuildSpec, _)
	parsed = Json.parse(text)
	spec = parsed.map_err(|_| Invalid("invalid build specification"))?
	source = path(spec.project)
	safe_tree!(source)?
	check_inputs!(spec.readlink, path(spec.inputs))?
	top = Env.cwd!()?
	work = top.join("blueprint-work")
	work.create_dir!()?
	copy_tree!(source, work)?
	# Store files are read-only; the project copy is the build's to change.
	Cmd.new(OsStr.from_str(spec.chmod)).args(["-R", "u+w", "--"].map(OsStr.from_str)).arg(work.to_os_str()).exec!()?
	home = top.join("blueprint-home")
	home.create_dir!()?
	cache = roc_build_cache!(spec.roc_packages, spec.ln, top)?
	match spec.argv {
		[] => return Err(Invalid("empty build command"))
		[program, .. as rest] => {
			# A bare program name resolves against the PATH given here.
			base = Cmd.new(OsStr.from_str(program)).args(rest.map(OsStr.from_str)).cwd(work)
				.env(OsStr.from_str("PATH"), OsStr.from_str(spec.path))
				.env(OsStr.from_str("HOME"), home.to_os_str())
				.env(OsStr.from_str("BLUEPRINT_INPUTS"), OsStr.from_str(spec.inputs))
				.env(OsStr.from_str("BLUEPRINT_ARTIFACTS"), OsStr.from_str(spec.artifacts))
			# Only the user command sees the cache, and only when there is one.
			command = match cache {
				Private(directory) => base.env(OsStr.from_str("XDG_CACHE_HOME"), directory.to_os_str())
				NoCache => base
			}
			ran = command.stdout(Inherit).stderr(Inherit).run!()
			match ran {
				Ok(Cmd.Output.{ status: Exited(0), .. }) => {}
				Ok(Cmd.Output.{ status: Exited(code), .. }) => return Err(Exited(code))
				Ok(Cmd.Output.{ status: Signaled(signal), .. }) => return Err(Exited(128 + signal))
				Err(CmdErr(StartFailed(NotFound, _))) => return Err(Invalid("build command not found: ${program}"))
				Err(CmdErr(StartFailed(err, _))) => return Err(Invalid("cannot run ${program}: ${Str.inspect(err)}"))
				Err(_) => return Err(Invalid("cannot run ${program}"))
			}
		}
	}
	parts = output_parts(spec.output)?
	if (work.is_sym_link!() ?? False) or !(work.is_dir!() ?? False) {
		return Err(Invalid("build replaced the project workspace"))
	}
	# basic-cli has no no-follow open, so a build still running in the
	# background could swap an entry between these checks and the copy.
	var $depth = parts.len()
	while $depth > 0 {
		ancestor = work.join(Str.join_with(parts.take_first($depth), "/"))
		if ancestor.is_sym_link!() ?? False {
			return Err(Invalid("symlink in declared output path: ${ancestor.display()}"))
		}
		$depth = $depth - 1
	}
	output = work.join(spec.output)
	if !(output.exists!() ?? False) {
		return Err(Invalid("declared output is missing: ${spec.output}"))
	}
	if !within(
		output.canonicalize!()?.to_os_str().to_bytes(),
		work.canonicalize!()?.to_os_str().to_bytes(),
	) {
		return Err(Invalid("declared output escapes the project workspace"))
	}
	safe_tree!(output)?
	destination = Path.from_os_str(
		Env.var!(OsStr.from_str("out")).map_err(|_| Invalid("the build has no $out"))?,
	)
	if (destination.is_sym_link!() ?? False) or (destination.exists!() ?? False) {
		return Err(Invalid("build wrote directly to $out instead of declared Output"))
	}
	if output.is_dir!()? {
		destination.create_dir!()?
		copy_tree!(output, destination)
	} else {
		output.copy!(destination)?
		Ok({})
	}
}

## A build has no network, so Roc cannot download a package there. Give the
## build a cache of its own holding its environment's locked bundles: Roc reads
## `$XDG_CACHE_HOME/roc/packages/<hash>/main.roc` and does not download what it
## finds. Links suffice, because the cache is discarded with the build
## directory and the store cannot be collected while the build runs. basic-cli
## cannot create a link itself.
roc_build_cache! : Try(List(RocPackage), [Missing]), Try(Str, [Missing]), Path => Try([Private(Path), NoCache], _)
roc_build_cache! = |declared, ln, top| {
	bundles = declared ?? []
	if bundles.is_empty() {
		return Ok(NoCache)
	}
	program = ln.map_err(|_| Invalid("the build has Roc packages but no ln program"))?
	cache = top.join("blueprint-cache")
	directory = cache.join("roc").join("packages")
	directory.create_all!()?
	for bundle in bundles {
		if !Project.valid_name(bundle.name) {
			return Err(Invalid("invalid Roc package name: ${bundle.name}"))
		}
		if !(path(bundle.path).join("main.roc").is_file!() ?? False) {
			return Err(Invalid("Roc package ${bundle.name} has no main.roc"))
		}
		Cmd.new(OsStr.from_str(program)).args(["-s", "--", bundle.path].map(OsStr.from_str))
			.arg(directory.join(bundle.name).to_os_str())
			.exec!()
			.map_err(|_| Invalid("cannot link Roc package ${bundle.name}"))?
	}
	Ok(Private(cache))
}

## Reject Run even when the daemon ignores client sandbox flags: the build's
## namespaces must both differ from those the caller observed for itself.
require_isolation! : Str => Try({}, _)
require_isolation! = |text| {
	witness : Try({ isolation : { mnt : Str, net : Str } }, _)
	witness = Json.parse(text)
	caller = witness.map_err(|_| Invalid("${isolation_remedy} Missing caller namespace observations."))?.isolation
	tools : Try({ readlink : Str }, _)
	tools = Json.parse(text)
	readlink = tools.map_ok(|parsed| parsed.readlink)
	# Two calls, not a loop: this Roc nightly miscounts references when a loop
	# body matches on a value from outside it.
	require_namespace!(readlink, "mnt", caller.mnt)?
	require_namespace!(readlink, "net", caller.net)
}

isolation_remedy : Str
isolation_remedy =
	"cannot verify build isolation; user Run was not executed. "
		.concat("Enable sandbox = true and sandbox-fallback = false in the Nix ")
		.concat("daemon configuration and use a local Linux sandbox with /proc.")

require_namespace! : Try(Str, _), Str, Str => Try({}, _)
require_namespace! = |readlink, name, observed| {
	if !valid_namespace(name, observed) {
		return Err(Invalid("${isolation_remedy} Invalid caller ${name} namespace."))
	}
	current = match readlink {
		Ok(program) => observe_namespace!(program, name)
		Err(_) => Err("no readlink program")
	}
		.map_err(|reason| Invalid("${isolation_remedy} Cannot read build ${name} namespace: ${reason}"))?
	if !valid_namespace(name, current) {
		return Err(Invalid("${isolation_remedy} Invalid build ${name} namespace."))
	}
	if current == observed {
		return Err(Invalid("${isolation_remedy} Build shares caller ${name} namespace."))
	}
	Ok({})
}

## A declared output is a relative path of plain names.
output_parts : Str -> Try(List(Str), _)
output_parts = |output| {
	parts = output.split_on("/")
	if parts.any(|part| part == "" or part == "." or part == "..") {
		Err(Invalid("invalid declared relative output"))
	} else {
		Ok(parts)
	}
}

expect output_parts("dist/my artifact") == Ok(["dist", "my artifact"])
expect
	["", "/absolute", ".", "..", "./artifact", "dist/../escape", "dist//file", "dist/"].all(
		|output| output_parts(output) == Err(Invalid("invalid declared relative output")),
	)

## Reject links and special files anywhere in a tree, by raw entry names.
safe_tree! : Path => Try({}, _)
safe_tree! = |entry|
	match entry.type!()? {
		IsSymLink => Err(Invalid("symlink is not allowed in build output/source: ${entry.display()}"))
		IsDir => {
			for child in entry.list!()? {
				safe_tree!(child)?
			}
			Ok({})
		}
		IsFile => Ok({})
		IsOther => Err(Invalid("special file is not allowed in build output/source: ${entry.display()}"))
	}

## Allow generated farm links, not symlinks within fetched source trees.
check_inputs! : Str, Path => Try({}, _)
check_inputs! = |readlink, farm| {
	for entry in farm.list!()? {
		if !(entry.is_sym_link!()?) {
			return Err(Invalid("expected generated source link: ${entry.display()}"))
		}
		target = Cmd.new(OsStr.from_str(readlink)).args(["-n", "--"].map(OsStr.from_str)).arg(entry.to_os_str())
			.run!().map_err(|err| Invalid(Str.inspect(err)))?.require_success()
			.map_err(|_| Invalid("cannot read generated source link: ${entry.display()}"))?
			.stdout_bytes
		# Follow exactly the planner's farm link. safe_tree! rejects a symlink
		# at the fetched root or anywhere beneath it, including remote inputs.
		resolved = if target.first() == Ok('/') {
			target
		} else {
			farm.to_os_str().to_bytes().append('/').concat(target)
		}
		safe_tree!(Path.unix_bytes(resolved))?
	}
	Ok({})
}

basename : List(U8) -> List(U8)
basename = |bytes| bytes.fold([], |acc, byte| if byte == '/' [] else acc.append(byte))

expect basename("/project/src/main.roc".to_utf8()) == "main.roc".to_utf8()

## Copy the directories and regular files of a tree safe_tree! accepted into
## an existing directory, by raw entry names. Files keep their permissions.
copy_tree! : Path, Path => Try({}, _)
copy_tree! = |source, target| {
	for entry in source.list!()? {
		name = basename(entry.to_os_str().to_bytes())
		copy = Path.unix_bytes(target.to_os_str().to_bytes().append('/').concat(name))
		if entry.is_dir!()? {
			copy.create_dir!()?
			copy_tree!(entry, copy)?
		} else {
			entry.copy!(copy)?
		}
	}
	Ok({})
}

## The pure planner validates the entire request before any staging effects.
realise! : Spec, Request, Context => Try({}, _)
realise! = |spec, request, ctx| {
	layout = ctx.layout
	# What the Spec alone rules out is said before the authority is read.
	Realise.preflight(spec, request, ctx.target, layout, providers).map_err(|problems| PlanFailed(problems))?
	if !(path(layout.lock_path).exists!()?) {
		return Err(LockFailed("missing authoritative lock; run `blueprint update`"))
	}
	safe_path!(layout.lock_path)?
	if path(layout.lock_path).type!()? != IsFile {
		return Err(UnsafePath(layout.lock_path))
	}
	lock = Lock.parse(path(layout.lock_path).read_utf8!()?)
		.map_err(|_| LockFailed("unsupported Blueprint lock format; run blueprint update"))?
	# Stale for every project: said as what it is, not as what changed.
	if Lock.from_before_explicit_sources(lock) {
		return Err(OldLock)
	}
	lock.stale(spec).map_err(|message| LockFailed(message))?
	# Everything that stops the request is known, and said together, before
	# the first effect of any step.
	steps = Realise.plan(spec, request, ctx.target, layout, lock, providers)
		.map_err(|problems| PlanFailed(problems))?
	# A build cannot run on this host: say so before the first step's effects.
	for step in steps.steps {
		for operation in step.operations {
			match operation {
				Runner({ system, .. }) => runner_host(host_system!(), system)?
				_ => {}
			}
		}
	}
	present!(steps.steps, request)?
	fetched = fetch_programs!(steps.steps)?
	for step in steps.steps {
		execute_step!(step, fetched, ctx)?
	}
	Ok({})
}

## What a request is to its user, for a message.
subject : Request -> Str
subject = |request|
	match request {
		Request.Shell(_) => "the shell"
		Request.Build(_) => "the build"
		Request.Generate => "this"
		_ => "the task"
	}

## Every program the steps need the machine to have already (see `Present`
## in `Steps.Operation`), looked up on PATH without being started. All of
## them are checked, for every step, before anything is downloaded or run,
## so one refusal names everything that is missing.
present! : List(Steps.Step), Request => Try({}, _)
present! = |steps, request| {
	var $missing = []
	var $checked = []
	for step in steps {
		for operation in step.operations {
			match operation {
				Present(entries) => {
					for entry in entries {
						if !$checked.contains(entry) {
							$checked = $checked.append(entry)
							if !Cmd.check_available!(entry.program) {
								$missing = $missing.append("  ${entry.program}: ${entry.because}")
							}
						}
					}
				}
				_ => {}
			}
		}
	}
	if $missing.is_empty() {
		Ok({})
	} else {
		Err(Refused("this machine lacks what ${subject(request)} needs, and blueprint installs none of it:\n${Str.join_with($missing, "\n")}"))
	}
}

## A fetched program and its real path in the store.
Fetched : { program : Steps.Program, file : Str }

## Every program the steps name (see `Programs` in `Steps.Operation`), each
## verified and made ready in the store once, before the first step runs.
fetch_programs! : List(Steps.Step) => Try(List(Fetched), _)
fetch_programs! = |steps| {
	var $wanted = []
	for step in steps {
		for operation in step.operations {
			match operation {
				Programs(programs) => {
					for program in programs {
						if !$wanted.contains(program) {
							$wanted = $wanted.append(program)
						}
					}
				}
				_ => {}
			}
		}
	}
	if $wanted.is_empty() {
		return Ok([])
	}
	store = Store.root!().map_err(|message| FetchFailed(message))?
	var $fetched = []
	for program in $wanted {
		file = Store.program!(store, program, Lock).map_err(|message| FetchFailed(message))?
		$fetched = $fetched.append({ program, file })
	}
	Ok($fetched)
}

## One consumer-owned executor for standalone requests and workflow steps.
## All planning has succeeded, every expected program has been found and
## every fetched one is in the store before the first materialization or task
## effect.
execute_step! : Steps.Step, List(Fetched), Context => Try({}, _)
execute_step! = |step, fetched, ctx| {
	layout = ctx.layout
	var $files = step.files
	var $roc_bundles = []
	var $programs = []
	for operation in step.operations {
		match operation {
			VerifyTree({ path: local, digest }) => {
				safe_source!(local)?
				if tree_digest!(local)? != digest {
					return Err(
						LockFailed(
							"local source ${local} changed; run `blueprint update`",
						),
					)
				}
			}
			Isolation(placeholder) => {
				mnt = namespace!("mnt")?
				net = namespace!("net")?
				$files = $files.map(
					|file| {
						..file,
						contents: file.contents.replace_each(placeholder.mnt, mnt)
							.replace_each(placeholder.net, net),
					},
				)
			}
			Runner({ executable, system }) => {
				own = runner_executable!(system)?
				$files = $files.map(
					|file| { ..file, contents: file.contents.replace_each(executable, own) },
				)
			}
			RocBundles(bundles) => {
				$roc_bundles = $roc_bundles.concat(bundles)
			}
			# Checked for every step before the first one started.
			Present(_) => {}
			Programs(programs) => {
				for program in programs {
					entry = fetched.find_first(|known| known.program == program)
						.map_err(|_| FetchFailed("${program.name} was not fetched before the step that needs it"))?
					$programs = $programs.append({ name: program.name, file: entry.file })
				}
			}
		}
	}
	stage!($files, layout)?
	publish_roc_bundles!($roc_bundles, ctx)?
	if $programs.is_empty() {
		start!(step, [], "", layout)
	} else {
		# The step's own directory of links, first on its PATH and gone when
		# it ends, however it ends.
		runs = "${layout.generated_root}/run"
		safe_path!(layout.generated_root)?
		path(runs).create_all!()?
		ignore_generated!(layout)?
		run = Env.create_temp_dir_in!(path(runs), "run-")?
		linked! = || {
			bin = "${Paths.portable(run.to_str()?)}/bin"
			path(bin).create_dir!()?
			for program in $programs {
				Store.expose!(bin, program.name, program.file).map_err(|message| FetchFailed(message))?
			}
			start!(step, $programs.map(|program| program.name), bin, layout)
		}
		result = linked!()
		_ = run.delete_all!()
		result
	}
}

## Start a step's command from the project root, with `bin` ahead of the
## caller's PATH when the step has programs there. A program the argv names
## that is one of them is started from `bin` itself, whatever the caller's
## PATH would have found. A shell with no argv is the caller's own: `SHELL`,
## or `/bin/sh`.
start! : Steps.Step, List(Str), Str, Layout => Try({}, _)
start! = |step, names, bin, layout| {
	directories = if bin.is_empty() [] else [bin]
	match step.action {
		Build(name) => report_build!(step, name, layout.project_root)
		Shell(_) if step.argv.is_empty() => {
			shell = match Env.var_str!("SHELL") {
				Ok(value) if !value.is_empty() => value
				_ => "/bin/sh"
			}
			exec_within!([shell], layout.project_root, directories)
		}
		_ => {
			argv = match step.argv {
				[program, .. as rest] if Env.platform!().os == WINDOWS and names.contains(program) => ["${bin}/${Store.executable_name(program)}"].concat(rest)
				_ => started(step.argv, names, bin)
			}
			exec_within!(argv, layout.project_root, directories).map_err(
				|err|
					match (step.action, err) {
						(Run(name), CommandFailed(_, code)) => TaskFailed(name, code)
						_ => err
					},
			)
		}
	}
}

## An argv whose program is one of the step's linked programs, by its link.
started : List(Str), List(Str), Str -> List(Str)
started = |argv, names, bin|
	match argv {
		[program, .. as rest] if names.contains(program) => ["${bin}/${program}"].concat(rest)
		_ => argv
	}

expect started(["roc-stable", "version"], ["roc-stable"], "/p/.blueprint/run/x/bin") == ["/p/.blueprint/run/x/bin/roc-stable", "version"]
expect started(["printf", "roc-stable"], ["roc-stable"], "/b") == ["printf", "roc-stable"]
expect started(["/usr/bin/roc-stable"], ["roc-stable"], "/b") == ["/usr/bin/roc-stable"] and started([], ["roc-stable"], "/b") == []

## The directory Roc reads URL packages from, as bytes: `roc/packages` under
## `XDG_CACHE_HOME` when that is set, otherwise under `.cache` in `HOME`. Roc
## takes a relative value against its working directory, which for a shell or
## task is the project root.
roc_package_cache : Try(List(U8), _), Try(List(U8), _), List(U8) -> Try(List(U8), [NoRocPackageCache])
roc_package_cache = |xdg_cache_home, home, root| {
	base = match (xdg_cache_home, home) {
		(Ok(directory), _) => directory
		(Err(_), Ok(directory)) => directory.concat("/.cache".to_utf8())
		(Err(_), Err(_)) => return Err(NoRocPackageCache)
	}
	absolute = if base.first() == Ok('/') base else root.append('/').concat(base)
	Ok(absolute.concat("/roc/packages".to_utf8()))
}

expect roc_package_cache(Ok("/xdg".to_utf8()), Ok("/home/me".to_utf8()), "/project".to_utf8()) == Ok("/xdg/roc/packages".to_utf8())
expect roc_package_cache(Err(Unset), Ok("/home/me".to_utf8()), "/project".to_utf8()) == Ok("/home/me/.cache/roc/packages".to_utf8())
expect roc_package_cache(Ok("cache".to_utf8()), Ok("/home/me".to_utf8()), "/project".to_utf8()) == Ok("/project/cache/roc/packages".to_utf8())
expect roc_package_cache(Ok([0xff, '/', 'c']), Err(Unset), "/project".to_utf8()) == Ok("/project/".to_utf8().concat([0xff]).concat("/c/roc/packages".to_utf8()))
expect roc_package_cache(Err(Unset), Err(Unset), "/project".to_utf8()) == Err(NoRocPackageCache)

## Where Roc keeps URL packages on Windows, in the form held here: Roc reads
## `XDG_CACHE_HOME` there too, then `LOCALAPPDATA`, and `HOME` last.
windows_package_cache : Try(Str, _), Try(Str, _), Try(Str, _), Str -> Try(Str, [NoRocPackageCache])
windows_package_cache = |xdg_cache_home, local_app_data, home, root| {
	base = match (xdg_cache_home, local_app_data, home) {
		(Ok(directory), _, _) => directory
		(Err(_), Ok(directory), _) => directory
		(Err(_), Err(_), Ok(directory)) => "${directory}/.cache"
		(Err(_), Err(_), Err(_)) => return Err(NoRocPackageCache)
	}
	Ok(Paths.normalize("${Paths.resolve(root, base)}/roc/packages"))
}

expect windows_package_cache(Err(Unset), Ok("C:\\Users\\me\\AppData\\Local"), Ok("C:\\Users\\me"), "D:/a/project") == Ok("C:/Users/me/AppData/Local/roc/packages")
expect windows_package_cache(Ok("D:\\cache"), Ok("C:\\Users\\me\\AppData\\Local"), Err(Unset), "D:/a/project") == Ok("D:/cache/roc/packages")
expect windows_package_cache(Ok("cache"), Err(Unset), Err(Unset), "D:/a/project") == Ok("D:/a/project/cache/roc/packages")
expect windows_package_cache(Err(Unset), Err(Unset), Ok("C:\\Users\\me"), "D:/a/project") == Ok("C:/Users/me/.cache/roc/packages")
expect windows_package_cache(Err(Unset), Err(Unset), Err(Unset), "D:/a/project") == Err(NoRocPackageCache)

## Roc's package cache on this host.
roc_package_cache! : Str => Try(Path, _)
roc_package_cache! = |root| {
	unknown = |_| RocPackagesFailed("neither XDG_CACHE_HOME nor HOME says where Roc's package cache is")
	match Env.platform!().os {
		WINDOWS => {
			text! = |name| Env.var_str!(OsStr.from_str(name))
			directory = windows_package_cache(text!("XDG_CACHE_HOME"), text!("LOCALAPPDATA"), text!("HOME"), root)
				.map_err(|_| RocPackagesFailed("none of XDG_CACHE_HOME, LOCALAPPDATA and HOME says where Roc's package cache is"))?
			Ok(path(directory))
		}
		_ => {
			xdg_cache_home = Env.var!(OsStr.from_str("XDG_CACHE_HOME")).map_ok(|value| value.to_bytes())
			home = Env.var!(OsStr.from_str("HOME")).map_ok(|value| value.to_bytes())
			Ok(Path.unix_bytes(roc_package_cache(xdg_cache_home, home, root.to_utf8()).map_err(unknown)?))
		}
	}
}

## An entry of a directory, in the directory's own representation.
child : Path, Str -> Path
child = |directory, name| directory.join(name)

## A directory of its own in Roc's package cache, for whatever is being
## published as `name`. It is renamed to end in `.tmp`: Roc sweeps directories
## of that name from its cache once they are a day old, so one abandoned by a
## killed process does not stay forever.
roc_package_staging! : Path, Str => Try(Path, _)
roc_package_staging! = |cache, name| {
	failed = |err| RocPackagesFailed("cannot stage Roc package ${name} in ${cache.display()}: ${Str.inspect(err)}")
	created = Env.create_temp_dir_in!(cache, "blueprint-${name}.").map_err(failed)?
	staging = match created.filename() {
		Ok(own) => child(cache, "${own.display()}.tmp")
		Err(err) => {
			_ = created.delete_all!()
			return Err(failed(err))
		}
	}
	match created.rename!(staging) {
		Ok({}) => Ok(staging)
		Err(err) => {
			_ = created.delete_all!()
			Err(failed(err))
		}
	}
}

## Make each named bundle resolvable by Roc without Roc downloading it (see
## `RocBundles` in `Steps.Operation`), for every task and shell, whether or
## not a provider enters its environment: a missing one is downloaded and the
## compiler unpacks it, which fails unless the bytes are those the bundle's
## name is the hash of. A bundle that is already there, whether Roc
## downloaded it or an earlier run published it, is left alone, and when
## none is missing nothing is fetched. Roc may lose its cache at any time;
## the next run publishes again.
publish_roc_bundles! : List({ name : Str, url : Str }), Context => Try({}, _)
publish_roc_bundles! = |bundles, ctx| {
	if bundles.is_empty() {
		return Ok({})
	}
	cache = roc_package_cache!(ctx.layout.project_root)?
	var $missing = []
	for bundle in bundles {
		if !Project.valid_name(bundle.name) {
			return Err(RocPackagesFailed("invalid Roc package name: ${bundle.name}"))
		}
		if !roc_package_present!(cache, bundle.name) {
			$missing = $missing.append(bundle)
		}
	}
	if $missing.is_empty() {
		return Ok({})
	}
	compiler = roc!(ctx)?
	cache.create_all!().map_err(|_| RocPackagesFailed("cannot create Roc's package cache ${cache.display()}"))?
	for bundle in $missing {
		fresh = roc_package_staging!(cache, "${bundle.name}.download")?
		unbundle! = || {
			file = "${bundle.name}.tar.zst"
			Stderr.line!("blueprint: fetching Roc package ${bundle.name} from ${bundle.url}")?
			bytes = Download.get!(bundle.url).map_err(|reason| RocPackagesFailed("could not download Roc package ${bundle.name} from ${bundle.url}: ${reason}; nothing was published"))?
			child(fresh, file).write_bytes!(bytes).map_err(|_| RocPackagesFailed("cannot write Roc package ${bundle.name} in ${fresh.display()}"))?
			# What the compiler says while unpacking is kept off the standard
			# output, which is the task's own.
			_ = Cmd.new(OsStr.from_str(compiler)).args(["unbundle", file].map(OsStr.from_str)).cwd(fresh).run!()?.require_success()
				.map_err(|_| RocPackagesFailed("Roc package ${bundle.name} from ${bundle.url} is not the bundle its name is the hash of: `roc unbundle` refused it; nothing was published"))?
			publish_roc_package!(cache, bundle.name, child(fresh, bundle.name))
		}
		result = unbundle!()
		cleanup = fresh.delete_all!()
		result?
		cleanup.map_err(|_| RocPackagesFailed("published Roc package ${bundle.name} but could not delete ${fresh.display()}"))?
	}
	Ok({})
}

## Roc resolves a URL package from `<cache>/<hash>/main.roc` alone.
roc_package_present! : Path, Str => Bool
roc_package_present! = |cache, name| child(child(cache, name), "main.roc").is_file!() ?? False

## Publish one bundle as `<cache>/<name>` from `source`, the tree the
## compiler unpacked. Unpacking was the check of its bytes against the
## bundle's name, so nothing is hashed again here.
##
## Every Roc process reads this cache, so `main.roc` must never appear before
## the rest. The tree is copied into a staging directory in the cache
## directory itself and then renamed into place, which is atomic. Whatever
## happens, the staging directory is deleted on the way out.
publish_roc_package! : Path, Str, Path => Try({}, _)
publish_roc_package! = |cache, name, source| {
	if !(source.join("main.roc").is_file!() ?? False) {
		return Err(RocPackagesFailed("Roc package ${name} has no main.roc in ${source.display()}"))
	}
	final = child(cache, name)
	staging = roc_package_staging!(cache, name)?
	publish! = || {
		# The staging directory is private (mode 0700); the package is a
		# child with ordinary permissions, so it can be deleted like any other.
		staged = child(staging, name)
		staged.create_dir!()?
		copy_roc_package!(source, staged)?
		first = staged.rename!(final)
		# Losing the rename to another process costs nothing: its bytes are ours.
		if first.is_ok() or roc_package_present!(cache, name) {
			return Ok({})
		}
		# Otherwise something without a `main.roc` holds the name: an
		# interrupted extraction, or a link whose target is gone. Roc treats
		# that as incomplete and replaces it; do the same rather than leave Roc
		# to download it. It is moved aside, not deleted in place, so the name
		# is empty only between two renames.
		final.rename!(child(staging, "${name}.incomplete"))
			.map_err(|_| RocPackagesFailed("cannot publish Roc package ${name}: ${final.display()} has no main.roc and cannot be replaced"))?
		second = staged.rename!(final)
		if second.is_ok() or roc_package_present!(cache, name) {
			Ok({})
		} else {
			Err(RocPackagesFailed("cannot publish Roc package ${name} as ${final.display()}"))
		}
	}
	result = publish!()
	cleanup = staging.delete_all!()
	result?
	cleanup.map_err(|_| RocPackagesFailed("published Roc package ${name} but could not delete ${staging.display()}"))
}

## Copy a bundle's directories and regular files by raw entry names. Files
## keep their permissions; directories are created anew and writable, so the
## package can be deleted. A bundle holds no links or special files.
copy_roc_package! : Path, Path => Try({}, _)
copy_roc_package! = |source, target| {
	for entry in source.list!()? {
		copy = match entry.to_raw() {
			# Windows has no path of bytes; a name there is text or it is refused.
			WindowsU16s(_) => {
				own = entry.filename().map_err(|_| RocPackagesFailed("Roc package holds an entry without a name: ${entry.display()}"))?
				child(target, own.to_str().map_err(|_| RocPackagesFailed("Roc package holds a name that is not text: ${entry.display()}"))?)
			}
			_ => Path.unix_bytes(target.to_os_str().to_bytes().append('/').concat(basename(entry.to_os_str().to_bytes())))
		}
		match entry.type!()? {
			IsDir => {
				copy.create_dir!()?
				copy_roc_package!(entry, copy)?
			}
			IsFile => entry.copy!(copy)?
			_ => return Err(RocPackagesFailed("Roc package holds a link or special file: ${entry.display()}"))
		}
	}
	Ok({})
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
			result = Cmd.new(OsStr.from_str(program)).args(args.map(OsStr.from_str)).cwd(path(root))
				.stderr(Inherit).capture!()?
			Stdout.write!(result)?
			Stderr.line!(
				"built ${artifact.name}: ${artifact.installable} -> "
					.concat(result.trim()),
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
		path(Paths.parent(file.path)).create_all!()?
		atomic_write!(file.path, file.contents)?
	}
	if files.is_empty() {
		Ok({})
	} else {
		ignore_generated!(layout)
	}
}

## Generated state is not for version control, so the generated root ignores
## its own contents. The file is written once and never again: what a caller
## put there stays, and an unchanged project stages nothing new.
ignore_generated! : Layout => Try({}, _)
ignore_generated! = |layout| {
	ignore = Layout.ignore_file(layout)
	safe_path!(ignore)?
	if path(ignore).exists!()? {
		Ok({})
	} else {
		atomic_write!(ignore, "*\n")
	}
}

## What tasks need on the target System, from the Spec alone: nothing is
## looked up on PATH, in the store or in the Lock, so the report can be asked
## for before anything is installed and says the same wherever it is asked.
report_requirements! : Spec, Bool, List(Str), Context => Try({}, _)
report_requirements! = |spec, json, tasks, ctx| {
	needs = Realise.requirements(spec, ctx.target, tasks, providers).map_err(|problems| PlanFailed(problems))?
	Stdout.write!(if json requirements_json(needs) else requirements_text(needs))
}

## The report for a reader: the System, the providers the tasks need between
## them, then each task with what supplies its environment.
requirements_text : Realise.Requirements -> Str
requirements_text = |needs| {
	listed = |what, names| if names.is_empty() [] else ["${what} ${Str.join_with(names, ", ")}"]
	task = |entry| {
		parts = (if entry.providers.is_empty() [] else ["${if entry.providers.len() == 1 "provider" else "providers"} ${Str.join_with(entry.providers, ", ")} (${Str.join_with(entry.tools, ", ")})"])
			.concat(listed("programs", entry.programs))
			.concat(listed("unavailable on ${needs.system}:", entry.unavailable))
			.concat(listed("expects", entry.expects))
			.concat(if entry.roc_packages == 0 [] else ["roc packages ${entry.roc_packages.to_str()}"])
		"task ${entry.task} [${entry.environment}]: ${if parts.is_empty() "nothing to supply" else Str.join_with(parts, "; ")}"
	}
	Str.join_with(
		["system ${needs.system}", "providers: ${if needs.providers.is_empty() "none" else Str.join_with(needs.providers, ", ")}"]
			.concat(needs.tasks.map(task))
			.concat([""]),
		"\n",
	)
}

## The report for a program, as JSON whose shape `format` numbers: a change
## that a reader of format 1 could misread gets another number.
##
## `providers` holds the name of every provider that must be on the machine
## to run the reported tasks on `system`: a provider is there exactly when
## one of those tasks has, in its environment on that System, a tool from a
## package source the provider supplies. A source that is declared and that
## no reported task uses does not put its provider there; neither does a
## shell, a build or `blueprint update`, which are not tasks. Each task
## repeats the question for itself. `expects` are the programs the machine
## must already have, and `unavailable` the fetched programs that do not
## exist for `system`.
requirements_json : Realise.Requirements -> Str
requirements_json = |needs| {
	texts = |items| "[${Str.join_with(items.map(|item| Json.to_str(item)), ",")}]"
	task = |entry|
		"{\"name\":${Json.to_str(entry.task)},\"environment\":${Json.to_str(entry.environment)},\"providers\":${texts(entry.providers)},\"tools\":${texts(entry.tools)},\"programs\":${texts(entry.programs)},\"unavailable\":${texts(entry.unavailable)},\"expects\":${texts(entry.expects)},\"roc_packages\":${entry.roc_packages.to_str()}}"
	tasks = if needs.tasks.is_empty() "[]" else "[\n ${Str.join_with(needs.tasks.map(task), ",\n ")}]"
	"{\"format\":${requirements_format.to_str()},\"system\":${Json.to_str(needs.system)},\"providers\":${texts(needs.providers)},\"expects\":${texts(needs.expects)},\"tasks\":${tasks}}\n"
}

## The number of the JSON report's shape.
requirements_format : U64
requirements_format = 1

needs_sample : Realise.Requirements
needs_sample = {
	system: "x86_64-linux",
	providers: ["guix"],
	expects: ["gh", "git"],
	tasks: [
		{ task: "check", environment: "dev", providers: [], tools: [], programs: ["roc-stable", "tool"], unavailable: [], expects: ["gh", "git"], roc_packages: 2 },
		{ task: "host", environment: "zig", providers: ["guix"], tools: ["stable#zigpkgs.\"0.16.0\"", "guix#git"], programs: ["roc-stable"], unavailable: ["tool"], expects: ["git"], roc_packages: 0 },
		{ task: "hello", environment: "plain", providers: [], tools: [], programs: [], unavailable: [], expects: [], roc_packages: 0 },
	],
}

expect requirements_text(needs_sample) == "system x86_64-linux\nproviders: guix\ntask check [dev]: programs roc-stable, tool; expects gh, git; roc packages 2\ntask host [zig]: provider guix (stable#zigpkgs.\"0.16.0\", guix#git); programs roc-stable; unavailable on x86_64-linux: tool; expects git\ntask hello [plain]: nothing to supply\n"
expect requirements_text({ system: "aarch64-darwin", providers: [], expects: [], tasks: [] }) == "system aarch64-darwin\nproviders: none\n"

# Every field is always there, in one order, and a name is quoted as JSON.
expect requirements_json(needs_sample) == "{\"format\":1,\"system\":\"x86_64-linux\",\"providers\":[\"guix\"],\"expects\":[\"gh\",\"git\"],\"tasks\":[\n {\"name\":\"check\",\"environment\":\"dev\",\"providers\":[],\"tools\":[],\"programs\":[\"roc-stable\",\"tool\"],\"unavailable\":[],\"expects\":[\"gh\",\"git\"],\"roc_packages\":2},\n {\"name\":\"host\",\"environment\":\"zig\",\"providers\":[\"guix\"],\"tools\":[\"stable#zigpkgs.\\\"0.16.0\\\"\",\"guix#git\"],\"programs\":[\"roc-stable\"],\"unavailable\":[\"tool\"],\"expects\":[\"git\"],\"roc_packages\":0},\n {\"name\":\"hello\",\"environment\":\"plain\",\"providers\":[],\"tools\":[],\"programs\":[],\"unavailable\":[],\"expects\":[],\"roc_packages\":0}]}\n"
expect requirements_json({ system: "aarch64-darwin", providers: [], expects: [], tasks: [] }) == "{\"format\":1,\"system\":\"aarch64-darwin\",\"providers\":[],\"expects\":[],\"tasks\":[]}\n"

# What is written is JSON a program reads back whole.
expect {
	parsed : Try({ format : U64, system : Str, providers : List(Str), expects : List(Str), tasks : List({ name : Str, environment : Str, providers : List(Str), tools : List(Str), programs : List(Str), unavailable : List(Str), expects : List(Str), roc_packages : U64 }) }, _)
	parsed = Json.parse(requirements_json(needs_sample))
	match parsed {
		Ok(read) => read.format == 1 and read.providers == ["guix"] and read.tasks.map(|entry| (entry.name, entry.providers, entry.roc_packages)) == [("check", [], 2), ("host", ["guix"], 0), ("hello", [], 0)] and read.tasks.map(|entry| entry.tools) == [[], ["stable#zigpkgs.\"0.16.0\"", "guix#git"], []]
		Err(_) => False
	}
}

list_tasks! : Spec => Try({}, _)
list_tasks! = |spec| {
	lines = spec.tasks.map(|t| "${t.name}\t(${t.environment})\t${Str.join_with(t.run, " ")}")
	Stdout.line!(Str.join_with(lines, "\n"))
}

## Explicit update alone resolves and atomically publishes the authority: one
## Lock for the pins a provider resolves and the digests of fetched programs.
##
## A provider is asked only when the project declares something it resolves
## (see `Realise.resolvers`), and the programs it needs on the machine are
## looked for first. A project that fetches, expects and has Roc packages for
## its tasks, and declares nothing else, is updated with no provider at all.
##
## With names it resolves those inputs and programs and keeps everything else
## of the authority, which must exist and be current for Blueprint.roc. An
## update of programs alone asks no provider.
resolve! : Spec, List(Str), Context => Try({}, _)
resolve! = |spec, names, ctx| {
	layout = ctx.layout
	safe_path!(layout.lock_path)?
	prior = authority_token!(layout.lock_path)?
	before = held!(layout)?
	declared = Project.unique(spec.programs.map(|program| program.name))
	wanted = names.keep_if(|name| declared.contains(name))
	others = names.keep_if(|name| !declared.contains(name))
	several = Refused("several providers have pins to resolve for this project, and one lock holds those of one")
	pins = if names.is_empty() {
		match Realise.resolvers(spec, providers) {
			[] => unpinned
			[provider] => pinned!(provider, spec, All, ctx)?
			_ => return Err(several)
		}
	} else {
		lock = match before {
			Held(found) => found
			Absent => return Err(LockFailed("no lock to keep the other pins from; run `blueprint update` without input names first"))
			Unreadable => return Err(LockFailed("unsupported Blueprint lock format; run `blueprint update` without input names"))
		}
		if Lock.from_before_explicit_sources(lock) {
			return Err(OldLock)
		}
		lock.stale(spec).map_err(|message| LockFailed("${message} without input names"))?
		if others.is_empty() {
			lock
		} else {
			match Realise.resolvers(spec, providers) {
				[] => return Err(Refused(Realise.unknown_names(others, [], declared)))
				[provider] => pinned!(provider, spec, Named(others, lock), ctx)?
				_ => return Err(several)
			}
		}
	}
	# What was recorded for a program stays while its URLs do; a provider
	# resolves package sources and knows nothing of downloads.
	known = match before {
		Held(found) => found.fetched
		_ => []
	}
	fetched = obtained!(Lock.refresh(spec.programs, known, if names.is_empty() All else Named(wanted)))?
	lock = { ..pins, intent: Lock.intent_of(spec), fetched }
	path(Paths.parent(layout.lock_path)).create_all!()?
	publish_authority!(layout.lock_path, prior, lock.to_str())?
	# A new place downloads come from is what a reviewer of the lock should
	# not miss among its digests.
	match Lock.new_hosts(known, fetched) {
		[] => Ok({})
		added => Stdout.line!("Blueprint.lock now names download hosts it did not name before:\n${Str.join_with(added.map(|host| "  ${host}"), "\n")}")
	}
}

## A Lock with no pins: what a project that asks no provider starts from.
unpinned : Lock
unpinned = Lock.{ format: Lock.current_format, intent: Lock.empty_intent, sources: [], hints: [], fetched: [] }

## The authority as it is now, when there is one that can be read.
held! : Layout => Try([Held(Lock), Absent, Unreadable], _)
held! = |layout| {
	if !(path(layout.lock_path).exists!()?) {
		return Ok(Absent)
	}
	if path(layout.lock_path).type!()? != IsFile {
		return Err(UnsafePath(layout.lock_path))
	}
	# Bytes that are not text are no more a Lock than text that is not one.
	match path(layout.lock_path).read_utf8!() {
		Ok(text) =>
			match Lock.parse(text) {
				Ok(lock) => Ok(Held(lock))
				Err(_) => Ok(Unreadable)
			}

		Err(_) => Ok(Unreadable)
	}
}

## The pins one provider resolves: what the machine must have is looked for
## before anything else, then the provider's files are staged and its argv
## run, and the native lock it wrote is converted.
pinned! : Provider, Spec, Provider.Update, Context => Try(Lock, _)
pinned! = |provider, spec, update, ctx| {
	layout = ctx.layout
	resolution = (provider.resolve)(spec, ctx.target, layout, update)
		.map_err(|message| RenderFailed(message))?
	var $missing = []
	for entry in resolution.present {
		if !Cmd.check_available!(entry.program) {
			$missing = $missing.append("  ${entry.program}: ${entry.because}")
		}
	}
	if !$missing.is_empty() {
		return Err(Refused("this machine lacks what blueprint update needs, and blueprint installs none of it:\n${Str.join_with($missing, "\n")}"))
	}
	# Reject ancestor escapes and nested symlinks before staging or fetching.
	var $trees = []
	for local in resolution.locals {
		safe_source!(local)?
		$trees = $trees.append({ path: local, digest: tree_digest!(local)? })
	}
	native_lock = resolution.native_lock
	safe_path!(native_lock)?
	if native_lock == layout.lock_path or !native_lock.starts_with("${layout.generated_root}/") {
		return Err(UnsafePath(native_lock))
	}
	# Derived state is disposable. Unlink it rather than letting the provider
	# follow a stale hard-link alias while explicitly resolving fresh pins; a
	# named update stages the native lock it keeps pins from.
	if path(native_lock).exists!()? {
		path(native_lock).delete!()?
	}
	stage!(resolution.files, layout)?
	exec!(resolution.argv, layout.project_root)?
	safe_path!(native_lock)?
	(provider.lock_from_native)(spec, layout, path(native_lock).read_utf8!()?, $trees)
		.map_err(|message| LockFailed(message))
}

## A release that has been asked about during this update, and its answer:
## each is asked once, however many of its assets are programs.
Asked : { api : Str, answer : [Described(Str), NoRelease, Unanswered(Str)] }

## The entries an update records, in order: those it keeps as they are and
## those whose digest it obtains (see `obtain!`).
obtained! : List(Lock.Refresh) => Try(List(Lock.Fetched), _)
obtained! = |plan| {
	host = host_system!() ?? ""
	var $entries = []
	var $asked = []
	for step in plan {
		recorded = record!(step, host, $asked)?
		$entries = $entries.append(recorded.entry)
		$asked = recorded.asked
	}
	Ok($entries)
}

record! : Lock.Refresh, Str, List(Asked) => Try({ entry : Lock.Fetched, asked : List(Asked) }, _)
record! = |step, host, asked|
	match step {
		Keep(entry) => Ok({ entry, asked })
		Obtain(program) => obtain!(program, host, asked)
	}

## The digest of one program on one System, obtained now. The download of
## the System this machine is, is fetched and hashed here, compared with what
## its release publishes when it publishes one, and kept in the store for the
## run that follows. When that download is the compiler this executable has
## already fetched for itself, the store's bytes are hashed and nothing is
## fetched a second time. Another System's is recorded by the published
## digest without being fetched, and fetched and hashed only when nothing is
## published for it. Two digests that differ record nothing.
obtain! : Spec.Program, Str, List(Asked) => Try({ entry : Lock.Fetched, asked : List(Asked) }, _)
obtain! = |program, host, asked| {
	looked = published!(program, asked)
	what = "${program.name} for ${program.system}"
	here = program.system == host
	held = if here compiler_held!(what, program) else Err(NotHeld)
	downloaded : Try({ sha256 : Str, size : U64, bytes : List(U8) }, [NotDownloaded])
	downloaded = if held.is_err() and (here or looked.published.is_err()) {
		Ok(Store.hashed!(what, program.urls).map_err(|message| FetchFailed(absent_advice(program, message)))?)
	} else {
		Err(NotDownloaded)
	}
	computed : Try(Lock.Digest, [NotDownloaded])
	computed = match held {
		Ok(found) => Ok(found)
		Err(_) => downloaded.map_ok(|found| { sha256: found.sha256, size: found.size })
	}
	entry = Lock.record(program, computed, looked.published)
		.map_err(|message| FetchFailed(message))?
	match downloaded {
		Ok(found) if here => {
			store = Store.root!().map_err(|message| FetchFailed(message))?
			Store.remember!(store, found.sha256, found.bytes).map_err(|message| FetchFailed(message))?
		}
		_ => {}
	}
	Ok({ entry, asked: looked.asked })
}

## What to add to a download's failure during an update. A recipe answers
## for every declared System unless it says `Unavailable`, as `Recipes.file`
## never does; a publisher that has no download for one of them answers 404,
## and the reader is told the two ways to say so in Blueprint.roc.
absent_advice : Spec.Program, Str -> Str
absent_advice = |program, message|
	if message.contains("HTTP 404 ") {
		"${message}\nIf ${program.name} is not published for ${program.system}, say so in Blueprint.roc: list the systems the project supports in Systems, or give ${program.name} a recipe that answers Unavailable for ${program.system}"
	} else {
		message
	}

expect {
	program = { name: "tool", system: "aarch64-darwin", urls: ["https://example.org/tool-aarch64-darwin"], unpack: File, path: "" }
	absent_advice(program, "could not download tool for aarch64-darwin from https://example.org/tool-aarch64-darwin: HTTP 404 from https://example.org/tool-aarch64-darwin (1 attempt)")
		== "could not download tool for aarch64-darwin from https://example.org/tool-aarch64-darwin: HTTP 404 from https://example.org/tool-aarch64-darwin (1 attempt)\nIf tool is not published for aarch64-darwin, say so in Blueprint.roc: list the systems the project supports in Systems, or give tool a recipe that answers Unavailable for aarch64-darwin"
		and absent_advice(program, "could not download tool: HTTP 503 from https://example.org/tool (3 attempts)") == "could not download tool: HTTP 503 from https://example.org/tool (3 attempts)"
}

## The digest of a program whose download is a compiler this executable
## records, when the store holds that download: the bytes it fetched to read
## Blueprint.roc, hashed again now.
compiler_held! : Str, Spec.Program => Try(Lock.Digest, [NotHeld])
compiler_held! = |what, program| {
	compiler = Bootstrap.serving(program.urls).map_err(|_| NotHeld)?
	store = Store.root!().map_err(|_| NotHeld)?
	found = Store.held!(store, compiler.sha256)?
	_ = Stderr.line!("blueprint: ${what} is the download of Roc this blueprint already holds; its digest is recorded from the store")
	Ok(found)
}

## What a program's release publishes for its download, when its first URL is
## a release asset: asked of the release's host, once for each release. A
## release that cannot be asked about is said so once, and every download of
## it is then hashed here, as for a host that publishes nothing.
published! : Spec.Program, List(Asked) => { published : Try(Lock.Digest, [NotPublished]), asked : List(Asked) }
published! = |program, asked| {
	release = match program.urls.first().map_ok(Published.release) {
		Ok(Ok(found)) => found
		_ => return { published: Err(NotPublished), asked }
	}
	known = match asked.find_first(|entry| entry.api == release.api) {
		Ok(entry) => asked.keep_if(|other| other.api != entry.api).append(entry)
		Err(_) => {
			_ = Stderr.line!("blueprint: asking ${release.api} what ${release.repository} publishes for its release ${release.tag}")
			answer = Published.ask!(release)
			_ = match answer {
				Unanswered(notice) => Stderr.line!("blueprint: ${notice}")
				_ => Ok({})
			}
			asked.append({ api: release.api, answer })
		}
	}
	published = match known.last().map_ok(|entry| entry.answer) {
		Ok(Described(text)) => Published.digest(text, release.asset).map_err(|_| NotPublished)
		_ => Err(NotPublished)
	}
	{ published, asked: known }
}

## Publish only if the authority still has the token observed before
## resolving, so an update that lost a race fails instead of rolling back a
## newer one. No lock is held (basic-cli has none): two updates that both pass
## the comparison before either renames can still overwrite each other.
publish_authority! : Str, Str, Str => Try({}, _)
publish_authority! = |destination, prior, contents| {
	temporary = Env.create_temp_dir_in!(
		path(Paths.parent(destination)),
		".blueprint-write-",
	)?
	publish! = || {
		staged = temporary.join("file")
		staged.write_utf8!(contents)?
		safe_path!(staged.to_str()?)?
		if staged.type!()? != IsFile {
			return Err(Refused("staged authority is not a regular file: ${staged.display()}"))
		}
		if authority_token!(destination)? != prior {
			return Err(Refused("authority changed during update; retry blueprint update"))
		}
		staged.rename!(path(destination))
	}
	result = publish!()
	_ = temporary.delete_all!()
	result
}

## Rename publication avoids truncation and overwriting hard-linked contents.
atomic_write! : Str, Str => Try({}, _)
atomic_write! = |destination, contents| {
	temporary = Env.create_temp_dir_in!(
		path(Paths.parent(destination)),
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

## `provider` names the providers a request may be planned with.
describe : _, Str -> Str
describe = |err, provider|
	match err {
		NoBlueprint => "there is no Blueprint.roc in the selected project root"
		UnsupportedHost =>
			"blueprint runs on x86_64 Linux, arm64 Linux and Apple Silicon macOS, "
				.concat("and on x86_64 Windows to run tasks only; ")
				.concat("Intel macOS is not supported. ")
				.concat("Systems/BLUEPRINT_TARGET describe outputs, ")
				.concat("not compiler host support")
		CompilerFailed(message) =>
			"could not execute the configuration compiler; "
				.concat("Roc ${compiler_version.trim()} is fetched automatically, ")
				.concat("or set ROC to its executable:\n${message}")
		# A message that already names the command is not told it twice.
		LockFailed(message) => if message.contains("blueprint update") message else "${message}; use `blueprint update` to initialize or deliberately refresh pins"
		OldLock => "Blueprint.lock was written by blueprint 0.5 or older, which gave every project a package source it did not declare; run `blueprint update` to resolve it again with this blueprint, and review what changes"
		PlanFailed([problem]) => problem
		PlanFailed(problems) => "this cannot be carried out:\n  ${Str.join_with(problems, "\n  ")}"
		UnsafePath(value) => "refusing unsafe or symlinked runtime path: ${value}"
		Refused(message) => message
		BadSpec(InvalidSexpr(msg)) => "could not read the Spec from Blueprint.roc: ${msg}"
		BadSpec(UnsupportedFormat({ major, minor })) => "Spec format ${U64.to_str(major)}.${U64.to_str(minor)} is not supported by this blueprint (understands major ${Spec.current_format.major.to_str()}); upgrade blueprint or change the platform version"
		NeedsFeatures(missing) => "Blueprint.roc needs features: ${Str.join_with(missing, ", ")}; upgrade blueprint"
		OldPlatform => "Blueprint.roc uses a roc-blueprint platform older than 0.6.0; update the platform URL in its app header and see docs/releases/0.6.0"
		InvalidProject(msg) => "invalid Spec project: ${msg}"
		RenderFailed(msg) => "cannot generate the ${provider} files: ${msg}"
		RocPackagesFailed(msg) => msg
		FetchFailed(msg) => msg
		BadSpec(MissingRequiredField("format")) => "Blueprint.roc uses an older roc-blueprint platform that this blueprint can't read; update the platform URL in its app header to a current release"
		BadSpec(MissingRequiredField(field)) => "the Spec from Blueprint.roc is missing ${field}"
		BadExitStatus(Cmd.Output.{ command, status, stderr_bytes, .. }) =>
			"`${command}` failed (${Str.inspect(status)}):\n".concat(Str.from_utf8_lossy(stderr_bytes))
		TaskFailed(name, code) => "task ${name} exited with code ${code.to_str()}"
		UnknownTask(name, known) => "no task named \"${name}\"; Blueprint.roc defines: ${Str.join_with(known, ", ")}"
		UnknownShell(name, known) => "no shell named \"${name}\"; Blueprint.roc defines: ${Str.join_with(known, ", ")}"
		CommandFailed(argv, code) => "`${Str.join_with(argv, " ")}` exited with code ${code.to_str()}"
		other => Str.inspect(other)
	}
