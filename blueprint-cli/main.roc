## `blueprint`: turns a `Blueprint.roc` into a working Nix environment.
##
## The Roc compiler validates `Blueprint.roc` and prints the blueprint Spec;
## this CLI consumes pure plans and owns file/process effects. Only explicit
## update publishes the authority; ordinary operations use its resolved pins.
app [main!] {
	core: "../blueprint-core/main.roc",
	nix: "../blueprint-nix/main.roc",
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.9.0/7j6KBFBEZ8pNMLQHkx9xiwyZ2PmwQPgKNDPUih6gKe77.tar.zst",
}

import pf.Cmd
import pf.Env
import pf.File
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
import core.Tree
import nix.NixProvider
import "../.roc-version" as compiler_version : Str

version : Str
version = "0.4.0-rc2"

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
	# A sandboxed build runs this executable as its builder. There is no
	# Blueprint.roc or compiler there, so dispatch before loading either.
	match raw_args {
		[first, .. as rest] if first.to_bytes() == "__build-runner".to_utf8() => return build_runner!(rest)
		_ => {}
	}
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
## An explicit ROC must be the compatible compiler. Otherwise a compatible
## `roc` on PATH is used, and failing that the provider fetches the release.
roc! : () => Try(Str, _)
roc! = || {
	expected = "Roc compiler version ${compiler_version.trim()}"
	match Env.var_str!("ROC") {
		Ok(override) => {
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
		Err(_) => {
			on_path = Cmd.new_str("roc").args_str(["version"]).exec_output!()
				.map_ok(|output| output.stdout_utf8.trim() == expected) ?? False
			if on_path {
				return Ok("roc")
			}
			fetch_roc!((provider.compiler)(compiler_version.trim()))
		}
	}
}

## Realise the compatible compiler through the provider. Its progress goes to
## stderr; stdout is the directory holding `bin/roc`.
fetch_roc! : List(Str) => Try(Str, _)
fetch_roc! = |argv|
	match argv {
		[program, .. as args] => {
			output = Cmd.new_str(program).args_str(args).stderr(Inherit).exec_output!()
				.map_err(
					|err| CompilerFailed(
						"could not fetch Roc ${compiler_version.trim()}: ${Str.inspect(err)}",
					),
				)?
			Ok("${output.stdout_utf8.trim()}/bin/roc")
		}
		[] => Err(CompilerFailed("the provider cannot fetch a compiler"))
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
		target: Env.var_str!("BLUEPRINT_TARGET") ?? host_target!(),
	})
}

## The configuration platform ships a host for these machines only.
check_host! : () => Try({}, [UnsupportedHost])
check_host! = ||
	match Env.platform!() {
		{ arch: X64, os: LINUX } => Ok({})
		{ arch: AARCH64, os: LINUX } => Ok({})
		{ arch: AARCH64, os: MACOS } => Ok({})
		{ arch: X64, os: MACOS } => Ok({})
		_ => Err(UnsupportedHost)
	}

## The System this machine realises by default. Unsupported hosts fall back
## to the Linux default and fail later in check_host!.
host_target! : () => Str
host_target! = || host_system!() ?? "x86_64-linux"

## The System this executable itself runs on.
host_system! : () => Try(Str, [UnsupportedHost])
host_system! = ||
	match Env.platform!() {
		{ arch: X64, os: LINUX } => Ok("x86_64-linux")
		{ arch: AARCH64, os: LINUX } => Ok("aarch64-linux")
		{ arch: AARCH64, os: MACOS } => Ok("aarch64-darwin")
		{ arch: X64, os: MACOS } => Ok("x86_64-darwin")
		_ => Err(UnsupportedHost)
	}

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
		and normalize(value) == value
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
				$entries = $entries.append({ path: relative, kind: File({ executable, digest: file_digest!(full)? }) })
			}
			_ => return Err(UnsafePath(full))
		}
	}
	Ok($entries)
}

## Bytes are read in bounded chunks; an empty chunk is the end of the file.
file_digest! : Str => Try(Crypto.SHA256.Digest, _)
file_digest! = |file| {
	reader = File.open_reader_with_capacity!(path(file), 65536)?
	var $hasher = Crypto.SHA256.Hasher.empty()
	var $chunk = reader.read_up_to!(65536)?
	while !$chunk.is_empty() {
		$hasher = $hasher.write($chunk)
		$chunk = reader.read_up_to!(65536)?
	}
	Ok($hasher.finish())
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
	Ok("sha256:${file_digest!(file)?.to_hex()}")
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
	output = Cmd.new_str(readlink).args_str(["/proc/self/ns/${name}"]).exec_output!()
		.map_err(
			|err|
				match err {
					NonZeroExitCode({ exit_code, .. }) => "readlink exited with code ${exit_code.to_str()}"
					_ => "could not run readlink"
				},
		)?
	Ok(output.stdout_utf8.drop_suffix("\n"))
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
	Cmd.new_str(spec.chmod).args_str(["-R", "u+w", "--"]).arg(work.to_os_str()).exec_cmd!()?
	home = top.join("blueprint-home")
	home.create_dir!()?
	cache = roc_build_cache!(spec.roc_packages, spec.ln, top)?
	match spec.argv {
		[] => return Err(Invalid("empty build command"))
		[program, .. as rest] => {
			# A bare program name resolves against the PATH given here.
			base = Cmd.new_str(program).args_str(rest).cwd(work)
				.env_str("PATH", spec.path)
				.env(OsStr.from_str("HOME"), home.to_os_str())
				.env_str("BLUEPRINT_INPUTS", spec.inputs)
				.env_str("BLUEPRINT_ARTIFACTS", spec.artifacts)
			# Only the user command sees the cache, and only when there is one.
			command = match cache {
				Private(directory) => base.env(OsStr.from_str("XDG_CACHE_HOME"), directory.to_os_str())
				NoCache => base
			}
			ran = command.stdout(Inherit).stderr(Inherit).run!()
			match ran {
				Ok({ status: Exited(0), .. }) => {}
				Ok({ status: Exited(code), .. }) => return Err(Exited(code))
				Ok({ status: Signaled(signal), .. }) => return Err(Exited(128 + signal))
				Err(IO(NotFound)) => return Err(Invalid("build command not found: ${program}"))
				Err(IO(err)) => return Err(Invalid("cannot run ${program}: ${Str.inspect(err)}"))
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
		Cmd.new_str(program).args_str(["-s", "--", bundle.path])
			.arg(directory.join(bundle.name).to_os_str())
			.exec_cmd!()
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
		target = Cmd.new_str(readlink).args_str(["-n", "--"]).arg(entry.to_os_str())
			.exec_output_bytes!()
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
	# A build cannot run on this host: say so before the first step's effects.
	for step in steps.steps {
		for operation in step.operations {
			match operation {
				Runner({ system, .. }) => runner_host(host_system!(), system)?
				_ => {}
			}
		}
	}
	for step in steps.steps {
		execute_step!(step, layout)?
	}
	Ok({})
}

## One consumer-owned executor for standalone requests and workflow steps.
## All planning has succeeded before the first materialization or task effect.
execute_step! : Steps.Step, Layout => Try({}, _)
execute_step! = |step, layout| {
	var $files = step.files
	var $roc_packages = []
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
			# Locating the bundles reads the files staged below.
			RocPackages(request) => {
				$roc_packages = $roc_packages.append(request)
			}
		}
	}
	stage!($files, layout)?
	for request in $roc_packages {
		publish_roc_packages!(request.names, request.locate, layout.project_root)?
	}
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

child : Path, Str -> Path
child = |directory, name| Path.unix_bytes(directory.to_os_str().to_bytes().append('/').concat(name.to_utf8()))

## Roc resolves a URL package from `<cache>/<hash>/main.roc` alone.
roc_package_present! : Path, Str => Bool
roc_package_present! = |cache, name| child(child(cache, name), "main.roc").is_file!() ?? False

## Make each named bundle resolvable by Roc without a download, by publishing
## the locked copy into Roc's package cache. A package that is already there,
## whether Roc downloaded it or an earlier run published it, is left alone, and
## when none is missing the provider is not asked anything. Roc may lose its
## cache at any time; the next run publishes again.
publish_roc_packages! : List(Str), List(Str), Str => Try({}, _)
publish_roc_packages! = |names, locate, root| {
	xdg_cache_home = Env.var!(OsStr.from_str("XDG_CACHE_HOME")).map_ok(|value| value.to_bytes())
	home = Env.var!(OsStr.from_str("HOME")).map_ok(|value| value.to_bytes())
	cache = Path.unix_bytes(
		roc_package_cache(xdg_cache_home, home, root.to_utf8())
			.map_err(|_| RocPackagesFailed("neither XDG_CACHE_HOME nor HOME says where Roc's package cache is"))?,
	)
	var $missing = []
	for name in names {
		if !Project.valid_name(name) {
			return Err(RocPackagesFailed("invalid Roc package name: ${name}"))
		}
		if !roc_package_present!(cache, name) {
			$missing = $missing.append(name)
		}
	}
	if $missing.is_empty() {
		return Ok({})
	}
	located = locate_roc_packages!(locate, root)?
	cache.create_all!().map_err(|_| RocPackagesFailed("cannot create Roc's package cache ${cache.display()}"))?
	for name in $missing {
		bundle = located.find_first(|entry| entry.name == name)
			.map_err(|_| RocPackagesFailed("the ${provider.name} provider did not locate Roc package ${name}"))?
		publish_roc_package!(cache, name, path(bundle.path))?
	}
	Ok({})
}

## Run the provider's argv; it prints where each locked bundle is unpacked.
locate_roc_packages! : List(Str), Str => Try(List(RocPackage), _)
locate_roc_packages! = |argv, root|
	match argv {
		[program, .. as args] => {
			output = Cmd.new_str(program).args_str(args).cwd(path(root)).stderr(Inherit).exec_output!()
				.map_err(|_| RocPackagesFailed("could not locate the locked Roc packages with `${Str.join_with(argv, " ")}`"))?
			located : Try(List(RocPackage), _)
			located = Json.parse(output.stdout_utf8)
			located.map_err(|_| RocPackagesFailed("the ${provider.name} provider did not say where the locked Roc packages are"))
		}
		[] => Err(RocPackagesFailed("the ${provider.name} provider cannot locate Roc packages"))
	}

## Publish one bundle as `<cache>/<name>`. The provider has already verified
## `source` against Blueprint.lock, so nothing is hashed again here.
##
## Every Roc process reads this cache, so `main.roc` must never appear before
## the rest. The tree is copied into a staging directory in the cache
## directory itself and then renamed into place, which is atomic. The staging
## directory is renamed to end in `.tmp` first: Roc sweeps directories of that
## name from its cache once they are a day old, so one abandoned by a killed
## process does not stay forever. Whatever happens, it is deleted on the way
## out.
publish_roc_package! : Path, Str, Path => Try({}, _)
publish_roc_package! = |cache, name, source| {
	if !(source.join("main.roc").is_file!() ?? False) {
		return Err(RocPackagesFailed("locked Roc package ${name} has no main.roc in ${source.display()}"))
	}
	final = child(cache, name)
	created = Env.create_temp_dir_in!(cache, "blueprint-${name}.")
		.map_err(|err| RocPackagesFailed("cannot stage Roc package ${name} in ${cache.display()}: ${Str.inspect(err)}"))?
	staging = Path.unix_bytes(created.to_os_str().to_bytes().concat(".tmp".to_utf8()))
	match created.rename!(staging) {
		Ok({}) => {}
		Err(err) => {
			_ = created.delete_all!()
			return Err(RocPackagesFailed("cannot stage Roc package ${name} in ${cache.display()}: ${Str.inspect(err)}"))
		}
	}
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
## keep their permissions, so they stay read-only as in the store; directories
## are created anew and writable, so the package can be deleted. A bundle
## holds no links or special files.
copy_roc_package! : Path, Path => Try({}, _)
copy_roc_package! = |source, target| {
	for entry in source.list!()? {
		copy = Path.unix_bytes(target.to_os_str().to_bytes().append('/').concat(basename(entry.to_os_str().to_bytes())))
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
	prior = authority_token!(layout.lock_path)?
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
	stage!(resolution.files, layout)?
	# Derived state is disposable. Unlink it rather than letting the provider
	# follow a stale hard-link alias while explicitly resolving fresh pins.
	if path(native_lock).exists!()? {
		path(native_lock).delete!()?
	}
	exec!(resolution.argv, layout.project_root)?
	safe_path!(native_lock)?
	resolved = (provider.lock_from_native)(spec, layout, path(native_lock).read_utf8!()?, $trees)
		.map_err(|message| LockFailed(message))?
	lock = { ..resolved, intent: Lock.intent_of(spec) }
	path(parent(layout.lock_path)).create_all!()?
	publish_authority!(layout.lock_path, prior, lock.to_str())
}

## Publish only if the authority still has the token observed before
## resolving, so an update that lost a race fails instead of rolling back a
## newer one. No lock is held (basic-cli has none): two updates that both pass
## the comparison before either renames can still overwrite each other.
publish_authority! : Str, Str, Str => Try({}, _)
publish_authority! = |destination, prior, contents| {
	temporary = Env.create_temp_dir_in!(
		path(parent(destination)),
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
			"Blueprint.roc execution requires Linux or macOS on x86_64 or arm64; "
				.concat("Systems/BLUEPRINT_TARGET describe outputs, ")
				.concat("not compiler host support")
		CompilerFailed(message) =>
			"could not execute the configuration compiler; "
				.concat("Roc ${compiler_version.trim()} is fetched automatically, ")
				.concat("or set ROC to its executable:\n${message}")
		LockFailed(message) => "${message}; use `blueprint update` to initialize "
			.concat("or deliberately refresh pins")
		UnsafePath(value) => "refusing unsafe or symlinked runtime path: ${value}"
		Refused(message) => message
		BadSpec(InvalidSexpr(msg)) => "could not read the Spec from Blueprint.roc: ${msg}"
		BadSpec(UnsupportedFormat({ major, minor })) => "Spec format ${U64.to_str(major)}.${U64.to_str(minor)} is not supported by this blueprint (understands major ${Spec.current_format.major.to_str()}); upgrade blueprint or change the platform version"
		NeedsFeatures(missing) => "Blueprint.roc needs features: ${Str.join_with(missing, ", ")}; upgrade blueprint"
		InvalidProject(msg) => "invalid Spec project: ${msg}"
		RenderFailed(msg) => "cannot generate the ${provider.name} files: ${msg}"
		RocPackagesFailed(msg) => msg
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
