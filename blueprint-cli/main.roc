## `blueprint`: executes declared environments, tasks, builds and workflows.
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
import pf.File
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
import core.BuildModel
import core.Activation
import core.Sexpr
import Bootstrap
import Download
import Paths
import Published
import Store
import LockReport
import BuildReport
import ProviderContractTest
import nix.NixProvider
import "compiler-version" as compiler_version : Str
import "compiler-archive" as compiler_archive : List(U8)

version : Str
version = "0.9.0"

## The providers a request may be planned with. This is the only reference to
## a concrete provider: everything else uses the Provider contract
## (docs/architecture.adoc, invariant 7; checked by scripts/test.roc). Which
## of them a request needs is not chosen here or by the caller's environment:
## `Realise.plan` routes environments through declared package-source owners
## and Builds through their explicit executors.
providers : List(Provider)
providers = [NixProvider.provider]

## The providers by name, for a message.
provider_names : Str
provider_names = Str.join_with(providers.map(|provider| provider.name), ", ")

Command : [
	CompilerVersion,
	LockShow({ json : Bool, names : List(Str) }),
	StoreVerify({ json : Bool, repair : Bool }),
	Gen,
	Shell(Str),
	Run({ task : Str, args : List(Str) }),
	Build({ name : Str, json : Bool, rebuild : Bool }),
	InspectBuild({ name : Str, json : Bool, prepare : Bool, explain : Bool }),
	Activate({ name : Str, format : ActivationFormat }),
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
		{
			json: Opt.flag({ short: "", long: "json", help: "Emit versioned build provenance as JSON." }),
			rebuild: Opt.flag({ short: "", long: "rebuild", help: "Rebuild the same locked recipe and fail if its output differs." }),
			target: Param.str({ name: "name", help: "The artifact to build.", default: NoDefault }),
		}.Cli,
		{ name: "build", description: "Build a sandboxed artifact and its dependencies", mapper: |options| Build({ name: options.target, json: options.json, rebuild: options.rebuild }) },
	)
	update_cmd = SubCmd.finish(
		Cli.map(
			Param.str_list({ name: "names", help: "Inputs and fetched programs to update, by name; all of them when none is given." }),
			|names| Update(names),
		),
		{ name: "update", description: "Update Blueprint.lock: the latest inputs, and the digests of fetched programs", mapper: |c| c },
	)
	lock_cmd = SubCmd.finish(
		SubCmd.required([
			SubCmd.finish(
				{
					json: Opt.flag({ short: "", long: "json", help: "Print the versioned JSON lock report." }),
					names: Param.str_list({ name: "names", help: "Locked sources or programs; all when omitted." }),
				}.Cli,
				{ name: "show", description: "Inspect committed pins without evaluating Blueprint.roc", mapper: |r| LockShow(r) },
			),
		]),
		{ name: "lock", description: "Inspect committed pins", mapper: |c| c },
	)
	store_cmd = SubCmd.finish(
		SubCmd.required([
			SubCmd.finish(
				{
					json: Opt.flag({ short: "", long: "json", help: "Print the report as one JSON object." }),
					repair: Opt.flag({ short: "", long: "repair", help: "Replace a tree or record that differs, and remove a damaged archive." }),
				}.Cli,
				{ name: "verify", description: "Unpack every stored archive again and compare its trees and their records, with no download", mapper: |r| StoreVerify(r) },
			),
		]),
		{ name: "store", description: "Inspect the store of downloads", mapper: |c| c },
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
					|build| SubCmd.finish(
						{
							json: Opt.flag({ short: "", long: "json", help: "Emit versioned build provenance as JSON." }),
							rebuild: Opt.flag({ short: "", long: "rebuild", help: "Rebuild the same locked recipe and fail if its output differs." }),
						}.Cli,
						{ name: build.name, description: "${build.output} [${build.environment}]", mapper: |options| Build({ name: build.name, json: options.json, rebuild: options.rebuild }) },
					),
				),
			),
			{ name: "build", description: "Build a sandboxed artifact and its dependencies", mapper: |c| c },
		)
		_ => generic_build_cmd
	}
	{ shell_cmd, run_cmd, about } =
		match loaded {
			Ok(spec) => {
				# Weaver rejects an empty subcommand list, so fall back to the
				# generic parsers when there are no shells or tasks.
				shell_cmd: if (spec.shells.is_empty())
					generic_shell_cmd
				else
					SubCmd.finish(
						Cli.map(SubCmd.optional(spec.shells.map(shell_choice)), |picked| Shell(picked ?? "default")),
						{ name: "shell", description: "Enter a shell's environment (default: \"default\")", mapper: |c| c },
					),
				run_cmd: if (spec.tasks.is_empty())
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

	inspect_build_cmd = |explain| SubCmd.finish(
		SubCmd.required([
			SubCmd.finish(
				{
					json: Opt.flag({ short: "", long: "json", help: "Render the shared build evidence as JSON." }),
					prepare: Opt.flag({ short: "", long: "prepare", help: "Prepare an exact native build identity without building." }),
					target: Param.str({ name: "name", help: "The declared build.", default: NoDefault }),
				}.Cli,
				{ name: "build", description: "Inspect a declared build", mapper: |options| InspectBuild({ name: options.target, json: options.json, prepare: options.prepare, explain }) },
			),
		]),
		{ name: if (explain) "explain" else "plan", description: if (explain) "Explain changes from the last successful local build" else "Inspect declared build inputs and dependencies", mapper: |command| command },
	)

	env_cmd = SubCmd.finish(
		{
			json: Opt.flag({ short: "", long: "json", help: "Render the activation as a JSON report." }),
			github_path: Opt.flag({ short: "", long: "github-path", help: "Print the lines a GitHub Actions step appends to $GITHUB_PATH." }),
			github_env: Opt.flag({ short: "", long: "github-env", help: "Print the lines a GitHub Actions step appends to $GITHUB_ENV." }),
			target: Param.str({ name: "name", help: "The declared shell.", default: NoDefault }),
		}.Cli,
		{ name: "env", description: "Print what entering a shell exports, without entering it", mapper: |options| Activate({ name: options.target, format: if (options.json) JsonReport else if (options.github_path) GithubPath else if (options.github_env) GithubEnv else ShellLines }) },
	)

	Cli.assert_valid(
		Cli.finish(
			SubCmd.optional([
				SubCmd.empty({ name: "compiler-version", description: "Print the bundled Roc compiler release tag", value: CompilerVersion }),
				SubCmd.empty({
					name: "gen",
					description: "Generate the Nix files from the lock (the default)",
					value: Gen,
				}),
				shell_cmd,
				run_cmd,
				build_cmd,
				inspect_build_cmd(False),
				inspect_build_cmd(True),
				env_cmd,
				workflow_cmd,
				SubCmd.empty({ name: "tasks", description: "List the tasks", value: Tasks }),
				update_cmd,
				lock_cmd,
				store_cmd,
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
	count = |n, one, many| if (n == 1) "1 ${one}" else "${n.to_str()} ${many}"
	shells = spec.shells.map(|s| s.name)
	tasks = spec.tasks.map(|t| t.name)
	task_part = if (tasks.is_empty()) "no tasks" else "${count(tasks.len(), "task", "tasks")} (${Str.join_with(tasks, ", ")})"
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
	# These inspectors must parse before project paths, configuration, host or
	# compiler overrides are observed. LockShow selects only its lock path;
	# StoreVerify reads only the store.
	independent_query = match raw_args {
		[first, ..] => ["compiler-version", "lock", "store"].any(|name| first.to_bytes() == name.to_utf8())
		_ => False
	}
	context = if (independent_query) Err(NoBlueprint) else context!()
	# Evaluation resolves and verifies the compiler once; every later use of
	# it in this process, such as `check` or publishing Roc packages, takes
	# the resolved path instead of verifying the store again.
	evaluated = match context {
		Ok(ctx) => evaluate!(ctx)
		Err(err) => Err(err)
	}
	loaded = evaluated.map_ok(|found| found.spec)
	prepared = match evaluated {
		Ok(found) => Ok(found.ctx)
		Err(_) => context
	}
	# basic-cli supplies arguments without the executable name.
	match Cli.parse_or_display_message(cli_for(loaded), raw_args, OsStr.to_raw) {
		Err(Help(message)) | Err(Version(message)) => Stdout.line!(message).map_err(|_| Exit(1))
		Err(InvalidUsage(message)) => {
			_ = Stderr.line!(message)
			Err(Exit(2))
		}
		Ok(command) =>
			match run!(command ?? Gen, loaded, prepared) {
				Ok({}) => Ok({})
				Err(err) => {
					_ = Stderr.line!("blueprint: ${describe(err, provider_names)}")
					Err(Exit(1))
				}
			}
	}
}

run! = |command, loaded, context| {
	match command {
		LockShow({ json, names }) => inspect_lock!(json, names)
		StoreVerify(options) => store_verify!(options)
		CompilerVersion => Stdout.line!(compiler_version.trim())
		Check => check!(loaded, context?)
		_ => {
			ctx = context?
			spec = loaded?
			match command {
				LockShow({ json, names }) => inspect_lock!(json, names)
				StoreVerify(options) => store_verify!(options)
				CompilerVersion => Stdout.line!(compiler_version.trim())
				Gen => realise!(spec, Request.Generate, ctx)
				Shell(name) => realise!(spec, Request.Shell(name), ctx)
				Run({ task, args }) => realise!(spec, Request.Run(task, args), ctx)
				Build(options) => realise!(spec, Request.Build(options.name), { ..ctx, build_json: options.json, rebuild: options.rebuild })
				InspectBuild(options) => inspect_build!(spec, options, ctx)
				Activate(options) => realise!(spec, Request.Shell(options.name), { ..ctx, build_mode: Activate, activation_format: options.format })
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

## This path intentionally avoids Context, host probing and project evaluation.
inspect_lock! = |json, names| {
	cwd = Paths.portable(Env.cwd!()?.to_str()?)
	root = Paths.resolve(cwd, Env.var_str!("BLUEPRINT_ROOT") ?? cwd)
	file = Paths.resolve(root, Env.var_str!("BLUEPRINT_LOCK") ?? "Blueprint.lock")
	text = path(file).read_utf8!()?
	lock = Lock.parse(text).map_err(|_| LockFailed("unsupported or malformed Blueprint.lock"))?
	report = LockReport.render(lock, names, json, providers).map_err(|message| LockFailed(message))?
	Stdout.write!(report)
}

## `blueprint store verify`: like `inspect_lock!`, it observes no project,
## host or compiler. It reads the store, and writes to it only to repair, and
## downloads nothing. It fails when anything it found was not intact, even
## when it has repaired that.
store_verify! : { json : Bool, repair : Bool } => Try({}, _)
store_verify! = |{ json, repair }| {
	store = Store.root!().map_err(|message| StoreFailed(message))?
	report = (if (repair) Store.repair!(store) else Store.verify!(store)).map_err(|message| StoreFailed(message))?
	Stdout.write!(if (json) store_json(report) else store_text(report))?
	if report.counts.intact == report.findings.len() {
		Ok({})
	} else if repair {
		Err(StoreFailed("the store was not intact; what differed is repaired as reported"))
	} else {
		Err(StoreFailed("the store is not intact; `blueprint store verify --repair` makes what differs again from its archive"))
	}
}

## How a verdict reads: in a line, in JSON, and what it says beside that.
verdict_words : Store.Verdict -> { label : Str, name : Str, detail : Str }
verdict_words = |verdict|
	match verdict {
		Intact => { label: "intact", name: "intact", detail: "" }
		ArchiveDamaged(detail) => { label: "archive damaged", name: "archive_damaged", detail }
		TreeDiffers(detail) => { label: "tree differs", name: "tree_differs", detail }
		RecordDiffers(detail) => { label: "record differs", name: "record_differs", detail }
		NoRecord => { label: "no record", name: "no_record", detail: "" }
		NoArchive => { label: "no archive", name: "no_archive", detail: "" }
	}

## One line for each finding and each repair, and a line that sums them up.
store_text : Store.Report -> Str
store_text = |report| {
	found = report.findings.map(
		|finding| {
			said = verdict_words(finding.verdict)
			if (said.detail.is_empty()) "${said.label} ${finding.item}" else "${said.label} ${finding.item}: ${said.detail}"
		},
	)
	repaired = report.repaired.map(|done| "repaired ${done.item}: ${done.action}")
	counts = report.counts
	others = [("archive damaged", counts.archive_damaged), ("tree differs", counts.tree_differs), ("record differs", counts.record_differs), ("no record", counts.no_record), ("no archive", counts.no_archive)]
		.keep_if(|(_, count)| count > 0)
		.map(|(label, count)| ", ${count.to_str()} ${label}")
	totals = "store ${report.store}: ${report.findings.len().to_str()} checked, ${counts.intact.to_str()} intact${Str.join_with(others, "")}${if (repaired.is_empty()) "" else "; ${repaired.len().to_str()} repaired"}"
	Str.join_with(found.concat(repaired).append(totals), "\n").concat("\n")
}

store_report_format : U64
store_report_format = 1

## The report as one JSON object, for a program to read. The store's own
## records stay S-expressions; this is presentation.
store_json : Store.Report -> Str
store_json = |report| {
	findings = report.findings.map(
		|finding| {
			said = verdict_words(finding.verdict)
			{ item: finding.item, verdict: said.name, detail: said.detail }
		},
	)
	Json.to_str({ format: store_report_format, store: report.store, findings, counts: report.counts, repaired: report.repaired }).concat("\n")
}

## Type-check Blueprint.roc (including whole-config validation), then reuse
## the Spec loaded for CLI parsing to check provider compatibility.
check! : Try(Spec, _), Context => Try({}, _)
check! = |loaded, ctx| {
	check_host!()?
	native_command!(OsStr.from_str(roc!(ctx)?)).args(["check", "Blueprint.roc"].map(OsStr.from_str))
		.cwd(path(ctx.layout.project_root)).exec!()
		.map_err(|err| CompilerFailed(Str.inspect(err)))?
	spec = loaded?
	_ = rendered(spec)?
	# A build whose executor this blueprint cannot drive is a configuration
	# problem, said here rather than at the first `build`.
	for executor in spec.executors {
		adapter = providers.find_first(|candidate| candidate.name == executor.provider).map_err(|_| InvalidProject("executor ${executor.name} names provider ${executor.provider}, which this blueprint does not register"))?
		(adapter.validate_executor)(executor).map_err(|message| InvalidProject(message))?
	}
	Stdout.line!("Blueprint.roc is valid")
}

## Compile and run Blueprint.roc, then parse the Spec it prints.
evaluate! : Context => Try({ spec : Spec, ctx : Context }, _)
evaluate! = |ctx| {
	root = ctx.layout.project_root
	if !(path("${root}/Blueprint.roc").exists!() ?? False) {
		return Err(NoBlueprint)
	}
	check_host!()?
	compiler = roc!(ctx)?
	resolved = { ..ctx, compiler: Resolved(compiler) }
	output = native_command!(OsStr.from_str(compiler)).args(["Blueprint.roc"].map(OsStr.from_str))
		.cwd(path(root)).capture!()
		.map_err(|err| CompilerFailed(Str.inspect(err)))?
	spec = Spec.parse(output).map_err(|err| BadSpec(err))?
	missing = spec.unsupported_features(providers.fold(Realise.features, |all, provider| all.concat(provider.features)))
	if !missing.is_empty() {
		return Err(NeedsFeatures(missing))
	}
	validated = Project.validate(spec).map_err(|message| InvalidProject(message))?
	Ok({ spec: validated, ctx: resolved })
}

## The files every provider would generate for the Spec.
rendered : Spec -> Try(List(Provider.File), _)
rendered = |spec| {
	var $files = []
	for provider in providers {
		$files = $files.concat((provider.render)(spec).map_err(|msg| RenderFailed(msg))?)
	}
	Ok($files)
}

## Roc's Windows package roots must use the same separators as the paths it
## resolves. Keep our portable paths internally, and pass native cache/home
## variables to child programs so a URL package stays within its root.
native_command! : OsStr => Cmd
native_command! = |program| {
	var $command = Cmd.new(program)
	if Env.platform!().os == WINDOWS {
		for name in ["XDG_CACHE_HOME", "LOCALAPPDATA", "HOME"] {
			match Env.var_str!(OsStr.from_str(name)) {
				Ok(value) => {
					$command = $command.env(OsStr.from_str(name), OsStr.from_str(value.replace_each("/", "\\")))
				}
				Err(_) => {}
			}
		}
	}
	$command
}

## Run an argv from the provider.
exec! : List(Str), Str => Try({}, _)
exec! = |argv, root|
	match argv {
		[program, .. as args] =>
			native_command!(OsStr.from_str(program))
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
			native_command!(OsStr.from_str(program))
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
## `roc` on PATH is used, and failing that the compiler archive embedded in
## this executable is kept in the store, by its digest. No provider is asked:
## reading a Blueprint.roc needs none installed.
roc! : Context => Try(Str, _)
roc! = |ctx| {
	expected = "Roc compiler version ${compiler_version.trim()}"
	match ctx.compiler {
		Resolved(compiler) => return Ok(compiler)
		Unresolved => {}
	}
	match Env.var_str!("ROC") {
		Ok(override) => {
			compiler = if override.contains("/") and !override.starts_with("/") {
				cwd = Env.cwd!()?.to_str()?
				"${cwd}/${override}"
			} else override
			output = native_command!(OsStr.from_str(compiler)).args(["version"].map(OsStr.from_str)).capture!()
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
			on_path = native_command!(OsStr.from_str("roc")).args(["version"].map(OsStr.from_str)).capture!()
				.map_ok(|output| output.trim() == expected) ?? False
			if on_path {
				return Ok("roc")
			}
			tag = compiler_version.trim()
			system = host_system!()?
			program = Bootstrap.compiler(tag, system)
				.map_err(|_| CompilerFailed("this blueprint records no download of Roc ${tag} for ${system}"))?
			store = Store.root!().map_err(|message| CompilerFailed("could not install embedded Roc ${tag}: ${message}"))?
			Store.embedded_program!(store, program, compiler_archive).map_err(|message| CompilerFailed("could not install embedded Roc ${tag}: ${message}"))
		}
	}
}

## How `env` renders an activation: shell exports to `eval`, a JSON report,
## or the lines a GitHub Actions step appends to its path or env file.
ActivationFormat : [ShellLines, JsonReport, GithubPath, GithubEnv]

Context : { layout : Layout, target : Str, build_json : Bool, rebuild : Bool, build_sources : List(Lock.Source), build_pins : List(Lock.Source), build_spec : Spec, build_mode : [Execute, Plan, Explain, Activate], activation_format : ActivationFormat, compiler : [Unresolved, Resolved(Str)] }

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
		build_json: False,
		rebuild: False,
		build_sources: [],
		build_pins: [],
		build_spec: Spec.empty(""),
		build_mode: Execute,
		activation_format: ShellLines,
		compiler: Unresolved,
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

## Runtime namespace authorization is local to one kernel and system.
runner_host : Try(Str, [UnsupportedHost]), Str -> Try({}, _)
runner_host = |host, system|
	if host == Ok(system) {
		Ok({})
	} else {
		Err(
			Refused(
				"sandboxed builds verify isolation on the local kernel, so "
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
	dir = if (prefix == "") root else "${root}/${prefix}"
	for child in path(dir).list!()? {
		full = child.to_str()?
		name = full.split_on("/").last() ?? full
		relative = if (prefix == "") name else "${prefix}/${name}"
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
	base = if (ancestor == ['/']) [] else ancestor
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
	output = native_command!(OsStr.from_str(readlink)).args(["/proc/self/ns/${name}"].map(OsStr.from_str)).capture!()
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

basename : List(U8) -> List(U8)
basename = |bytes| bytes.fold([], |acc, byte| if (byte == '/') [] else acc.append(byte))

expect basename("/project/src/main.roc".to_utf8()) == "main.roc".to_utf8()

## The pure planner validates the entire request before any staging effects.
realise! : Spec, Request, Context => Try({}, _)
realise! = |spec, request, ctx| {
	layout = ctx.layout
	# What the Spec alone rules out is said before the authority is read.
	Realise.preflight(spec, request, ctx.target, layout, providers).map_err(|problems| PlanFailed(problems))?
	lock = read_lock!(layout)?
	lock.stale(spec).map_err(|message| LockFailed(message))?
	# Everything that stops the request is known, and said together, before
	# the first effect of any step.
	steps = Realise.plan(spec, request, ctx.target, layout, lock, providers)
		.map_err(|problems| PlanFailed(problems))?
	# Capability refusals precede downloads, staging and runtime authorization.
	for step in steps.steps {
		match step.action {
			Build(name) => {
				artifact = step.artifacts.find_first(|entry| entry.name == name).map_err(|_| RenderFailed("missing build artifact"))?
				adapter = providers.find_first(|entry| entry.name == artifact.provider).map_err(|_| RenderFailed("missing build adapter"))?
				required = ["builds", "prepare"].concat(if (ctx.rebuild) ["checked-rebuild"] else [])
				missing = required.keep_if(|capability| !adapter.build_capabilities.contains(capability))
				if !missing.is_empty() {
					return Err(RenderFailed("provider ${adapter.name} does not support ${Str.join_with(missing, ", ")}"))
				}
			}
			_ => {}
		}
	}
	# A build cannot run on this host: say so before the first step's effects.
	for step in steps.steps {
		for operation in step.operations {
			match operation {
				LocalSystem(system) => {
					if ctx.build_mode == Execute {
						runner_host(host_system!(), system)?
					}
				}
				_ => {}
			}
		}
	}
	present!(steps.steps, request)?
	fetched = fetch_programs!(steps.steps)?
	for step in steps.steps {
		(used, measured_pins) = match step.action {
			Build(name) => {
				artifact = step.artifacts.find_first(|item| item.name == name).map_err(|_| RenderFailed("build plan is missing artifact ${name}"))?
				adapter = providers.find_first(|candidate| candidate.name == artifact.provider).map_err(|_| RenderFailed("unknown build provider: ${artifact.provider}"))?
				names = (adapter.build_sources)(spec, name).map_err(|message| RenderFailed(message))?
				(names, snapshot_pins(lock, ctx.target, adapter).map_err(|message| RenderFailed(message))?)
			}
			_ => ([], [])
		}
		execute_step!(step, fetched, { ..ctx, build_spec: spec, build_pins: measured_pins, build_sources: lock.sources.keep_if(|source| used.contains(source.name)) })?
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

## Immutable provider bootstrap inputs can reuse the exact archive already
## carried by this executable. A name, version label or URL alone never matches.
source_is_embedded_compiler : Str, Str -> Bool
source_is_embedded_compiler = |sha256, system| Bootstrap.compiler(compiler_version.trim(), system).map_ok(|program| program.sha256 == sha256) ?? False

expect source_is_embedded_compiler("70346ac60dd0b0507881447c5b47aed799fd1bea01c50bac56f82ed96897f4df", "x86_64-linux")
expect !source_is_embedded_compiler("70346ac60dd0b0507881447c5b47aed799fd1bea01c50bac56f82ed96897f4df", "aarch64-darwin")
expect !source_is_embedded_compiler("different bytes", "x86_64-linux")

## One consumer-owned executor for standalone requests and workflow steps.
## All planning has succeeded, every expected program has been found and
## every fetched one is in the store before the first materialization or task
## effect.
execute_step! : Steps.Step, List(Fetched), Context => Try({}, _)
execute_step! = |step, fetched, ctx| {
	verify_tree_operations!(step.operations)?
	isolation = step.operations.find_first(
		|operation| match operation {
			Isolation(_) => True
			_ => False
		},
	)
	if ctx.build_mode != Execute {
		return execute_prepared!(step, fetched, ctx, "")
	}
	match isolation {
		Ok(Isolation({ directory, .. })) => {
			safe_path!(directory)?
			path(directory).create_all!()?
			created = Env.create_temp_dir_in!(path(directory), "blueprint-isolation-")?
			result = execute_prepared!(step, fetched, ctx, Paths.portable(created.to_str()?))
			_ = created.delete_all!()
			result
		}
		_ => execute_prepared!(step, fetched, ctx, "")
	}
}

verify_tree_operations! : List(Steps.Operation) => Try({}, _)
verify_tree_operations! = |operations| {
	for operation in operations {
		match operation {
			VerifyTree({ path: local, digest }) => {
				safe_source!(local)?
				if tree_digest!(local)? != digest {
					return Err(LockFailed("local source ${local} changed; run `blueprint update`"))
				}
			}
			_ => {}
		}
	}
	Ok({})
}

## A step's copies of project files (see `snapshot!`) are its provider's
## only while the step runs: by its end the provider has read them into its
## own store, and a copy left in a generated root would be read again with
## it by every later evaluation. Clear what an interrupted run left before
## anything is staged, and this step's copies once its command has ended,
## however it ended.
execute_prepared! : Steps.Step, List(Fetched), Context, Str => Try({}, _)
execute_prepared! = |step, fetched, ctx, witness_directory| {
	snapshots = snapshots_root(ctx.layout)
	clear_snapshots!(snapshots)
	result = run_prepared!(step, fetched, ctx, witness_directory)
	clear_snapshots!(snapshots)
	result
}

## Remove a directory of copies, unless it is not where it should be: a
## path through a link is never followed, and a refusal is said elsewhere.
clear_snapshots! : Str => {}
clear_snapshots! = |directory| {
	if safe_path!(directory).is_ok() and (path(directory).exists!() ?? False) {
		_ = path(directory).delete_all!()
	}
	{}
}

run_prepared! : Steps.Step, List(Fetched), Context, Str => Try({}, _)
run_prepared! = |step, fetched, ctx, witness_directory| {
	layout = ctx.layout
	var $files = step.files
	var $argv = step.argv
	var $roc_bundles = []
	var $programs = []
	var $originals = []
	for operation in step.operations {
		match operation {
			SourceFile(source) => {
				store = Store.root!().map_err(|message| FetchFailed(message))?
				file = if source_is_embedded_compiler(source.sha256, host_system!() ?? "") {
					Store.embedded_source_file!(store, source, compiler_archive).map_err(|message| FetchFailed(message))?
				} else {
					Store.source_file!(store, source).map_err(|message| FetchFailed(message))?
				}
				$originals = $originals.append({ sha256: source.sha256, file })
				marker = "@blueprint-source-file-${source.sha256}@"
				$files = $files.map(|entry| { ..entry, contents: entry.contents.replace_each(marker, Json.to_str(file)) })
			}
			Measure({ target, argv, marker, record }) => {
				local = match target {
					Snapshot(build) => snapshot!(step, build, ctx)?
					SourceFile(sha256) =>
						$originals.find_first(|original| original.sha256 == sha256)
							.map_ok(|original| original.file)
							.map_err(|_| FetchFailed("no original file with SHA-256 ${sha256} was staged before the step measured it"))?
				}
				identity = if argv.is_empty() {
					""
				} else {
					measure!(argv.append(local), ctx)?
				}
				text = measured_record(record, local, identity)
				$files = $files.map(|entry| { ..entry, contents: entry.contents.replace_each(marker, text) })
			}
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
			Isolation({ placeholder, .. }) => {
				if ctx.build_mode == Execute {
					mnt = namespace!("mnt")?
					net = namespace!("net")?
					atomic_write!("${witness_directory}/witness", "${mnt}\n${net}\n")?
					# Nix checks the source as its build user before mounting it. The
					# owned parent permits traversal but no listing or other-user writes;
					# the witness is readable even with a restrictive caller umask.
					Cmd.new("chmod").args(["0444", "--", "${witness_directory}/witness"].map(OsStr.from_str)).exec!()?
					Cmd.new("chmod").args(["0711", "--", witness_directory].map(OsStr.from_str)).exec!()?
					$argv = $argv.map(|arg| arg.replace_each(placeholder, witness_directory))
				}
			}
			LocalSystem(system) => {
				if ctx.build_mode == Execute {
					runner_host(host_system!(), system)?
				}
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
		start!({ ..step, argv: $argv }, [], "", ctx)
	} else if ctx.build_mode == Activate {
		bin = activation_bin!(step, $programs, ctx)?
		start!({ ..step, argv: $argv }, $programs.map(|program| program.name), bin, ctx)
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
			start!({ ..step, argv: $argv }, $programs.map(|program| program.name), bin, ctx)
		}
		result = linked!()
		_ = run.delete_all!()
		result
	}
}

## Run a Measure's command from the project root and take what it prints,
## trimmed, as the provider's identity of the content.
measure! : List(Str), Context => Try(Str, _)
measure! = |argv, ctx| {
	printed = capture_build_command!(argv, ctx)?.trim()
	if printed.is_empty() {
		return Err(RenderFailed("`${Str.join_with(argv, " ")}` printed no identity"))
	}
	Ok(printed)
}

## A Measure's record: `@path@` and `@identity@` in `template` replaced by
## the JSON strings of the two, neither looked for inside the other.
measured_record : Str, Str, Str -> Str
measured_record = |template, local, identity|
	Str.join_with(template.split_on("@path@").map(|part| part.replace_each("@identity@", Json.to_str(identity))), Json.to_str(local))

expect measured_record("{\"path\":@path@,\"narHash\":@identity@}", "/w/@identity@ \"q\"", "sha256-x=") == "{\"path\":\"/w/@identity@ \\\"q\\\"\",\"narHash\":\"sha256-x=\"}"
expect measured_record("{\"path\":@path@}", "/w/a", "") == "{\"path\":\"/w/a\"}"

## Copy the project files `build` selects (see `selected_walk!`) into a
## directory of their own in the workspace, emptied first, for the provider
## to read as a locked path. Names keep their bytes and files their
## permissions, so the provider sees what the build's evidence measures.
## The copy lasts until the step ends (see `execute_prepared!`).
snapshot! : Steps.Step, Str, Context => Try(Str, _)
snapshot! = |step, build, ctx| {
	layout = ctx.layout
	spec = Project.validate(ctx.build_spec).map_err(|message| RenderFailed(message))?
	artifact = step.artifacts.find_first(|item| item.name == build).map_err(|_| RenderFailed("build plan is missing artifact ${build}"))?
	adapter = providers.find_first(|candidate| candidate.name == artifact.provider).map_err(|_| RenderFailed("unknown build provider: ${artifact.provider}"))?
	exclusions = (adapter.build_exclusions)(spec, layout).map_err(|message| RenderFailed(message))?
	selection = build_selection(spec, build)
	walked = selected_walk!(layout.project_root, path(layout.project_root), "", [], selection.paths, selection.all, exclusions, layout)?
	missing_selected(selection.paths, walked.map(|entry| entry.path))?
	copy = snapshot_root(layout, build)
	safe_path!(copy)?
	if path(copy).exists!()? {
		path(copy).delete_all!()?
	}
	path(copy).create_all!()?
	if Layout.contains(layout.generated_root, copy) {
		ignore_generated!(layout)?
	}
	for entry in walked {
		target = beneath(copy, entry.raw)
		match entry.kind {
			Dir => target.create_dir!()?
			File => Path.copy!(entry.source, target).map_err(|err| RenderFailed("cannot copy ${entry.path} for build ${build}: ${Str.inspect(err)}"))?
		}
	}
	Ok(copy)
}

## Where the host copies builds' selected project files for their provider.
snapshots_root : Layout -> Str
snapshots_root = |layout| "${layout.workspace}/snapshots"

snapshot_root : Layout, Str -> Str
snapshot_root = |layout, build| "${snapshots_root(layout)}/${build}"

## `relative`, a path as listed, below `directory`, keeping its bytes.
beneath : Str, List(U8) -> Path
beneath = |directory, relative| Path.unix_bytes(directory.to_utf8().append('/').concat(relative))

expect Path.to_os_str(beneath("/w/snapshots/app", "a/b".to_utf8().append(255))).to_bytes() == "/w/snapshots/app/a/b".to_utf8().append(255)

## Start a step's command from the project root, with `bin` ahead of the
## caller's PATH when the step has programs there. A program the argv names
## that is one of them is started from `bin` itself, whatever the caller's
## PATH would have found. A shell with no argv is the caller's own: `SHELL`,
## or `/bin/sh`.
start! : Steps.Step, List(Str), Str, Context => Try({}, _)
start! = |step, names, bin, ctx| {
	layout = ctx.layout
	directories = if (bin.is_empty()) [] else [bin]
	if ctx.build_mode == Activate {
		return activate!(step, bin, ctx)
	}
	match step.action {
		Build(name) => report_build!(step, name, ctx)
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
	absolute = if (base.first() == Ok('/')) base else root.append('/').concat(base)
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
			_ = native_command!(OsStr.from_str(compiler)).args(["unbundle", file].map(OsStr.from_str)).cwd(fresh).run!()?.require_success()
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

## A lasting directory of links for an activation, under the workspace, so
## that what `env` printed stays valid after it exited. It is rebuilt each
## time, so it never holds a program the Lock no longer names.
activation_bin! : Steps.Step, List({ name : Str, file : Str }), Context => Try(Str, _)
activation_bin! = |step, programs, ctx| {
	layout = ctx.layout
	shell = match step.action {
		Shell(name) => name
		_ => return Err(ActivationFailed("only a shell's environment can be printed"))
	}
	bin = "${layout.workspace}/env/${shell}/bin"
	safe_path!(layout.workspace)?
	if path(bin).exists!()? {
		path(bin).delete_all!()?
	}
	path(bin).create_all!()?
	ignore_generated!(layout)?
	for program in programs {
		Store.expose!(bin, program.name, program.file).map_err(|message| FetchFailed(message))?
	}
	Ok(bin)
}

## What entering this step's environment exports, as data: the core's own
## directory of fetched programs, then what the provider's shell would
## export, asked for as data and never entered. Rendered as the caller asked.
activate! : Steps.Step, Str, Context => Try({}, _)
activate! = |step, bin, ctx| {
	own = Activation.{ path: if (bin.is_empty()) [] else [{ directory: bin, origin: "blueprint" }], variables: [] }
	provided = if step.argv.is_empty() {
		Activation.empty
	} else {
		adapter = providers.find_first(|candidate| (candidate.activation_argv)(step).is_ok())
			.map_err(|_| ActivationFailed("no provider of this blueprint can describe this environment as data"))?
		argv = (adapter.activation_argv)(step).map_err(|message| ActivationFailed(message))?
		text = match argv {
			[program, .. as args] => native_command!(OsStr.from_str(program)).args(args.map(OsStr.from_str)).cwd(path(ctx.layout.project_root)).stderr(Inherit).capture!()?
			[] => return Err(ActivationFailed("the provider named no command"))
		}
		(adapter.activation)(text).map_err(|message| ActivationFailed(message))?
	}
	activation = Activation.merge(own, provided)
	output = match ctx.activation_format {
		ShellLines => Activation.shell(activation)
		JsonReport => Activation.to_json(activation).map_err(|message| ActivationFailed(message))?.concat("\n")
		GithubPath => Activation.github(activation).path
		GithubEnv => Activation.github(activation).env
	}
	Stdout.write!(output)
}

## Decode every provider result once; execution uses the exact prepared recipe.
report_build! : Steps.Step, Str, Context => Try({}, _)
report_build! = |plan, name, ctx| {
	artifact = plan.artifacts.find_first(|item| item.name == name).map_err(|_| RenderFailed("build plan is missing artifact ${name}"))?
	adapter = providers.find_first(|candidate| candidate.name == artifact.provider).map_err(|_| RenderFailed("unknown build provider: ${artifact.provider}"))?
	# The provider reads the copies this step made, locked by their measured
	# identity, so the evidence measures those copies and not the project,
	# which may change meanwhile.
	copied = plan.operations.keep_oks(
		|operation|
			match operation {
				Measure({ target: Snapshot(build), .. }) => Ok(build)
				_ => Err(NotCopied)
			},
	)
	snapshot = build_snapshot!(ctx.build_spec, name, adapter, ctx.build_pins, copied, ctx)?
	preparation = (adapter.build_prepare_argv)(plan).map_err(|message| RenderFailed(message))?
	prepared_text = capture_build_command!(preparation, ctx)?
	prepared = (adapter.build_prepared)(prepared_text).map_err(|message| RenderFailed(message))?
	match ctx.build_mode {
		Activate => Err(ActivationFailed("a build has no environment to print; name a shell"))
		Plan => render_build_inspection!(snapshot, prepared, True, False, ctx)
		Explain => render_build_inspection!(snapshot, prepared, True, True, ctx)
		Execute => {
			argv = (adapter.build_execute_argv)(plan, prepared, { rebuild: ctx.rebuild }).map_err(|message| RenderFailed(message))?
			Stderr.line!("building ${name}: ${prepared.build_identity}")?
			result = capture_build_command!(argv, ctx)?
			built = (adapter.build_result)(result).map_err(|message| RenderFailed(message))?
			if built.build_identity != prepared.build_identity or built.outputs != prepared.outputs {
				return Err(RenderFailed("provider result does not match the prepared build"))
			}
			# Validate the public result consistently before advancing the baseline.
			json_report = BuildReport.render_evidence(name, ctx.target, adapter.name, built, ctx.build_sources, snapshot).map_err(|message| RenderFailed(message))?
			record = { schema_version: 1, snapshot, build_identity: built.build_identity, outputs: built.outputs }
			# The artifact exists whatever happens to the local record; a lost
			# record only leaves `explain` without a baseline.
			match save_build_record!(record, ctx) {
				Ok({}) => {}
				Err(problem) => Stderr.line!("warning: the local build record for ${name} was not saved, so `blueprint explain build ${name}` keeps its earlier baseline, if any: ${problem}")?
			}
			reported = if ctx.build_json {
				json_report
			} else {
				Str.join_with(built.outputs.map(|output| output.path), "\n").concat("\n")
			}
			Stdout.write!(reported)?
			Stderr.line!("built ${name}: ${built.build_identity} -> ${Str.join_with(built.outputs.map(|output| output.path), " ")}")
		}
	}
}

capture_build_command! : List(Str), Context => Try(Str, _)
capture_build_command! = |argv, ctx| {
	match argv {
		[program, .. as args] => native_command!(OsStr.from_str(program)).args(args.map(OsStr.from_str)).cwd(path(ctx.layout.project_root)).stderr(Inherit).capture!()
		[] => Err(RenderFailed("build operation has no command"))
	}
}

inspect_build! = |spec, options, ctx| {
	if options.prepare {
		mode = if (options.explain) Explain else Plan
		realise!(spec, Request.Build(options.name), { ..ctx, build_mode: mode, build_json: options.json })
	} else {
		validated = Project.validate(spec).map_err(|message| RenderFailed(message))?
		if !validated.systems.contains(ctx.target) {
			return Err(RenderFailed("execution system ${ctx.target} is not declared by the project"))
		}
		# Structural inspection needs no native execution preflight.
		executor = Project.build_executor(validated, options.name).map_err(|message| RenderFailed(message))?
		adapter = providers.find_first(|candidate| candidate.name == executor.provider).map_err(|_| RenderFailed("no build executor provider"))?
		(adapter.validate_executor)(executor).map_err(|message| RenderFailed(message))?
		lock = read_lock!(ctx.layout)?
		lock.stale(spec).map_err(|message| LockFailed(message))?
		# Inspect selected local pins independently of native host/layout limits.
		locals = (adapter.build_local_inputs)(validated, options.name, ctx.layout, lock).map_err(|message| RenderFailed(message))?
		verify_tree_operations!(locals.map(|local| VerifyTree({ path: local.path, digest: local.digest })))?
		snapshot = build_snapshot!(validated, options.name, adapter, snapshot_pins(lock, ctx.target, adapter).map_err(|message| RenderFailed(message))?, [], ctx)?
		render_build_inspection!(snapshot, { build_identity: "", outputs: [] }, False, options.explain, { ..ctx, build_json: options.json })
	}
}

## The committed authority, or why it cannot be read: a request never
## resolves pins itself, so a missing lock names the command that does.
read_lock! : Layout => Try(Lock, _)
read_lock! = |layout| {
	if !(path(layout.lock_path).exists!()?) {
		return Err(LockFailed("missing authoritative lock; run `blueprint update`"))
	}
	safe_path!(layout.lock_path)?
	if path(layout.lock_path).type!()? != IsFile {
		return Err(UnsafePath(layout.lock_path))
	}
	Lock.parse(path(layout.lock_path).read_utf8!()?).map_err(|_| LockFailed("unsupported Blueprint lock format; Blueprint 0.7 requires Lock 2"))
}

## Verified fetched tools share the named content-evidence model, not provider hints.
snapshot_pins : Lock, Str, Provider -> Try(List(Lock.Source), Str)
snapshot_pins = |lock, system, adapter| {
	projected = if lock.sources.any(|source| source.provider == adapter.name) {
		(adapter.inspect_lock)(lock)?
	} else {
		[]
	}
	pins = lock.sources.map(
		|source| {
			match projected.find_first(|entry| entry.name == source.name) {
				Ok(entry) => { ..source, digest: entry.content_identity }
				Err(_) => source
			}
		},
	)
	Ok(pins.concat(lock.fetched.keep_if(|entry| entry.system == system).map(|entry| { name: entry.name, provider: "blueprint", ref: "", rev: "", digest: "sha256:${entry.sha256}" })))
}

## The input evidence of a build and its closure. A build named in `copied`
## is measured in the copy of its selected files the step made for its
## provider; any other in the project itself, as structural planning does.
build_snapshot! : Spec, Str, Provider, List(Lock.Source), List(Str), Context => Try(BuildModel.Snapshot, _)
build_snapshot! = |input_spec, name, adapter, pins, copied, ctx| {
	spec = Project.validate(input_spec).map_err(|message| RenderFailed(message))?
	closure = Project.build_closure(spec, name).map_err(|message| RenderFailed(message))?
	exclusions = (adapter.build_exclusions)(spec, ctx.layout).map_err(|message| RenderFailed(message))?
	var $nodes = []
	for build in closure {
		selection = build_selection(spec, build.name)
		root = if (copied.contains(build.name)) snapshot_root(ctx.layout, build.name) else ctx.layout.project_root
		entries = selected_entries!(root, selection.paths, selection.all, exclusions, ctx.layout)?
		missing_selected(selection.paths, entries.map(|entry| entry.path))?
		files = entries.map(
			|entry| {
				digest = Tree.digest([entry]).map_err(|message| RenderFailed(message))?
				Ok({ path: entry.path, digest })
			},
		).fold(Ok([]), |acc, item| Ok(acc?.append(item?)))?
		sources = (adapter.build_inputs)(spec, build.name).map_err(|message| RenderFailed(message))?
		$nodes = $nodes.append(BuildModel.capture_node(spec, build, ctx.target, files, sources, pins).map_err(|message| RenderFailed(message))?)
	}
	Ok({ name, system: ctx.target, provider: adapter.name, nodes: $nodes })
}

## The paths a build selects with `Files`, or its whole project without them.
build_selection : Spec, Str -> { paths : List(Str), all : Bool }
build_selection = |spec, build|
	match spec.build_files.find_first(|entry| entry.build == build) {
		Ok(entry) => { paths: entry.paths, all: False }
		Err(_) => { paths: [], all: True }
	}

## A selected path that is not there is an error, not an unchanged or empty input.
missing_selected : List(Str), List(Str) -> Try({}, _)
missing_selected = |selected, found| {
	for item in selected {
		if !found.contains(item) {
			return Err(RenderFailed("missing selected build path: ${item}"))
		}
	}
	Ok({})
}

## The selected entries below `root` as evidence: each file's digest and
## whether it is executable.
selected_entries! : Str, List(Str), Bool, List(Str), Layout => Try(List(Tree.Entry), _)
selected_entries! = |root, selected, all, exclusions, layout| {
	var $entries = []
	for entry in selected_walk!(root, path(root), "", [], selected, all, exclusions, layout)? {
		kind = match entry.kind {
			Dir => Dir
			File => File({ executable: entry.source.is_executable!()?, digest: entry_digest!(entry.source)? })
		}
		$entries = $entries.append({ path: entry.path, kind })
	}
	Ok($entries)
}

## A project entry a build selects: its name in evidence, shown lossily when
## it is not UTF-8, and the bytes of that name as listed, relative to the
## root, and where it is.
Selected : { path : Str, raw : List(U8), source : Path, kind : [Dir, File] }

## The entries in `directory`, which is `prefix` (`raw_prefix` as listed)
## below `root`, that a build selects, each directory before what it holds.
## This is the one selection rule: the host copies exactly these for the
## provider to read (`snapshot!`) and measures exactly these as evidence. It
## leaves out what the Nix adapter's own filter left out before the host
## made the copy: VCS metadata named `.git`, `.hg`, `.svn` or `.jj` at any
## depth; the workspace, the generated root and the lock; and whatever the
## provider's `build_exclusions` names, by name at any depth or by absolute
## path. An excluded entry is never inspected. A selected symlink or special
## file is refused.
selected_walk! : Str, Path, Str, List(U8), List(Str), Bool, List(Str), Layout => Try(List(Selected), _)
selected_walk! = |root, directory, prefix, raw_prefix, selected, all, exclusions, layout| {
	var $entries = []
	for entry_path in directory.list!()? {
		# A name need not be UTF-8, and the copy keeps it as it is. Evidence
		# shows it lossily and keeps it distinct by its own digest.
		raw = basename_bytes(Path.to_os_str(entry_path).to_bytes())
		name = match Str.from_utf8(raw) {
			Ok(text) => text
			Err(_) => lossy_name(raw)
		}
		relative = if (prefix == "") name else "${prefix}/${name}"
		listed = if (raw_prefix.is_empty()) raw else raw_prefix.append('/').concat(raw)
		full = "${root}/${relative}"
		excluded = [".git", ".hg", ".svn", ".jj"].contains(name) or [layout.workspace, layout.generated_root, layout.lock_path].contains(full) or exclusions.contains(name) or exclusions.contains(full)
		included = all or selected.any(|item| relative == item or relative.starts_with("${item}/") or item.starts_with("${relative}/"))
		if !excluded and included {
			match entry_path.type!()? {
				IsDir => {
					$entries = $entries.append({ path: relative, raw: listed, source: entry_path, kind: Dir }).concat(selected_walk!(root, entry_path, relative, listed, selected, all, exclusions, layout)?)
				}
				IsFile => {
					$entries = $entries.append({ path: relative, raw: listed, source: entry_path, kind: File })
				}
				IsSymLink => return Err(Refused("snapshot refuses symlink: ${full}"))
				IsOther => return Err(Refused("snapshot refuses special file: ${full}"))
			}
		}
	}
	Ok($entries)
}

## The bytes after the last separator of a listed path.
basename_bytes : List(U8) -> List(U8)
basename_bytes = |raw| {
	var $start = 0
	var $index = 0
	for byte in raw {
		# A slash, or the backslash Windows lists with.
		if byte == 47 or byte == 92 {
			$start = $index + 1
		}
		$index = $index + 1
	}
	raw.drop_first($start)
}

## A name that is not UTF-8, shown lossily and kept distinct from any other
## by the first bytes of its own digest.
lossy_name : List(U8) -> Str
lossy_name = |raw| {
	tag = Str.from_utf8(Crypto.SHA256.hash(raw).to_hex().to_utf8().take_first(8)) ?? "unnamed"
	"${Str.from_utf8_lossy(raw)}~${tag}"
}

expect basename_bytes("/a/b/c.txt".to_utf8()) == "c.txt".to_utf8() and basename_bytes("plain".to_utf8()) == "plain".to_utf8()
expect lossy_name("x".to_utf8().append(255)).starts_with("x") and lossy_name("x".to_utf8().append(255)) != lossy_name("x".to_utf8().append(254))

## A listed file's SHA-256, read through its own path so that a name that is
## not UTF-8 is still measured.
entry_digest! : Path => Try(Crypto.SHA256.Digest, _)
entry_digest! = |file| {
	reader = File.open_reader_with_capacity!(file, 65536)?
	var $hasher = Crypto.SHA256.Hasher.empty()
	for! chunk in reader.chunks() {
		$hasher = $hasher.write(chunk?)
	}
	Ok($hasher.finish())
}

build_record_path : BuildModel.Snapshot, Context -> Str
build_record_path = |snapshot, ctx| "${ctx.layout.workspace}/build-records/${snapshot.system}/${snapshot.name}.scm"

save_build_record! : BuildModel.Record, Context => Try({}, Str)
save_build_record! = |record, ctx| {
	text = BuildModel.render_record(record)?
	file = build_record_path(record.snapshot, ctx)
	safe_path!(file).map_err(|err| describe(err, ""))?
	path(Paths.parent(file)).create_all!().map_err(|err| Str.inspect(err))?
	ignore_generated!(ctx.layout).map_err(|err| Str.inspect(err))?
	atomic_write!(file, text).map_err(|err| Str.inspect(err))
}

render_build_inspection! : BuildModel.Snapshot, Provider.PreparedBuild, Bool, Bool, Context => Try({}, _)
render_build_inspection! = |snapshot, prepared, exact, explain, ctx| {
	file = build_record_path(snapshot, ctx)
	safe_path!(file)?
	baseline = if path(file).exists!()? {
		text = path(file).read_utf8!()?
		BuildModel.parse_record(text)
	} else {
		Err("no successful local build record")
	}
	comparison = match baseline {
		Ok(previous) => BuildModel.compare(previous.snapshot, snapshot)
		Err(message) => Err(message)
	}
	changes = comparison ?? []
	status = match comparison {
		Ok(_) => "available"
		Err(_) => "unavailable"
	}
	reason = match comparison {
		Ok(_) => ""
		Err(message) => message
	}
	identity_status = if !exact or comparison.is_err() {
		"unavailable"
	} else {
		match baseline {
			Ok(previous) if previous.snapshot.provider == snapshot.provider => if (previous.build_identity == prepared.build_identity) "unchanged" else "changed"
			_ => "unavailable"
		}
	}
	adapter = providers.find_first(|candidate| candidate.name == snapshot.provider).map_err(|_| RenderFailed("unknown build provider"))?
	required = BuildModel.required_capabilities(snapshot).concat(if (exact) ["prepare"] else [])
	if ctx.build_json {
		inspection : BuildModel.Inspection
		inspection = { required_capabilities: required, provider_capabilities: adapter.build_capabilities, supported_guarantees: adapter.build_guarantees, schema_version: 1, name: snapshot.name, system: snapshot.system, provider: snapshot.provider, prepared: exact, build_identity: prepared.build_identity, outputs: prepared.outputs, snapshot_digest: BuildModel.digest(snapshot), snapshot, baseline: status, baseline_reason: reason, build_identity_status: identity_status, changes }
		Stdout.line!(Json.to_str(inspection))
	} else {
		Stdout.line!("build ${snapshot.name} [${snapshot.system}] via ${snapshot.provider}")?
		Stdout.line!("required capabilities: ${Str.join_with(required, ", ")}")?
		Stdout.line!("supported guarantees: ${Str.join_with(adapter.build_guarantees, ", ")}")?
		for node in snapshot.nodes {
			Stdout.line!("  ${node.name}: ${Json.to_str(node.command)} [${node.environment}; executor ${node.executor}] -> ${node.output}")?
			listed = |names| if (names.is_empty()) "none" else Str.join_with(names, ", ")
			Stdout.line!("  ${node.name}: ${node.files.len().to_str()} selected entries; inputs ${listed(node.inputs.map(|input| input.name))}; needs ${listed(node.dependencies)}")?
		}
		if exact {
			Stdout.line!("build identity: ${prepared.build_identity}")?
		}
		if explain {
			if status == "unavailable" {
				Stdout.line!("baseline unavailable: ${reason}")?
			} else {
				if changes.is_empty() {
					Stdout.line!("declared inputs unchanged")?
				}
				for change in changes {
					Stdout.line!("${Str.join_with(change.dependency_path, " -> ")}: ${change.kind}: ${change.name}")?
				}
				if exact {
					Stdout.line!("build identity ${identity_status}")?
				}
			}
		}
		Ok({})
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
	Stdout.write!(if (json) requirements_json(needs) else requirements_text(needs))
}

## The report for a reader: the System, the providers the tasks need between
## them, then each task with what supplies its environment.
requirements_text : Realise.Requirements -> Str
requirements_text = |needs| {
	listed = |what, names| if (names.is_empty()) [] else ["${what} ${Str.join_with(names, ", ")}"]
	task = |entry| {
		parts = (if (entry.providers.is_empty()) [] else ["${if (entry.providers.len() == 1) "provider" else "providers"} ${Str.join_with(entry.providers, ", ")} (${Str.join_with(entry.tools, ", ")})"])
			.concat(listed("programs", entry.programs))
			.concat(listed("unavailable on ${needs.system}:", entry.unavailable))
			.concat(listed("expects", entry.expects))
			.concat(if (entry.roc_packages == 0) [] else ["roc packages ${entry.roc_packages.to_str()}"])
		"task ${entry.task} [${entry.environment}]: ${if (parts.is_empty()) "nothing to supply" else Str.join_with(parts, "; ")}"
	}
	Str.join_with(
		["system ${needs.system}", "providers: ${if (needs.providers.is_empty()) "none" else Str.join_with(needs.providers, ", ")}"]
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
	tasks = if (needs.tasks.is_empty()) "[]" else "[\n ${Str.join_with(needs.tasks.map(task), ",\n ")}]"
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
resolve! = |input_spec, names, ctx| {
	spec = Project.validate(input_spec).map_err(|message| Refused(message))?
	layout = ctx.layout
	safe_path!(layout.lock_path)?
	prior = authority_token!(layout.lock_path)?
	before = held!(layout)?
	declared = Project.unique(spec.programs.map(|program| program.name).concat(spec.source_files.map(|source| source.name)))
	wanted = names.keep_if(|name| declared.contains(name))
	others = names.keep_if(|name| !declared.contains(name))
	if names.is_empty() or !others.is_empty() {
		owners = Project.unique(spec.sources.map(|source| source.provider.name).concat(spec.resolvers.map(|resolver| resolver.provider)))
		missing = owners.keep_if(|owner| !providers.any(|adapter| adapter.name == owner))
		if !missing.is_empty() {
			return Err(Refused("no registered resolver for ${Str.join_with(missing, ", ")}"))
		}
		if owners.len() > 1 {
			return Err(Refused("mixed resolver ownership is not supported"))
		}
	}
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
			Unreadable => return Err(LockFailed("unsupported Blueprint lock format; Blueprint 0.7 requires Lock 2"))
		}
		Lock.stale_except_files(lock, spec, wanted).map_err(|message| LockFailed("${message} without input names"))?
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
	fetched = obtained!(Lock.refresh(spec.programs, known, if (names.is_empty()) All else Named(wanted)))?
	# A published flat hash is verified before authority is published. A source
	# selected later uses the same pinned digest even with a fresh cache.
	for source in spec.source_files {
		if names.is_empty() or names.contains(source.name) {
			_ = Store.source_file!(Store.root!().map_err(|message| FetchFailed(message))?, source).map_err(|message| FetchFailed(message))?
		}
	}
	sources = pins.sources.keep_if(|source| source.provider != "file").concat(spec.source_files.map(Lock.file_pin))
	lock = { ..pins, intent: Lock.intent_of(spec), fetched, sources }
	# A new place downloads come from, declared or reached by a redirect, is
	# what a reviewer of the lock should not miss among its digests. It is
	# said before the lock is published: no lock names a host this update
	# did not say.
	notice = hosts_notice(known, fetched)
	if !notice.is_empty() {
		Stdout.line!(notice)?
	}
	path(Paths.parent(layout.lock_path)).create_all!()?
	publish_authority!(layout.lock_path, prior, lock.to_str())
}

## What an update says of the download hosts the lock it writes names and the
## lock before it did not, one to a line, each with how the lock came to name
## it: a URL Blueprint.roc declares, or a redirect from one. Empty when there
## is none.
hosts_notice : List(Lock.Fetched), List(Lock.Fetched) -> Str
hosts_notice = |before, after| {
	redirected = Lock.redirected(after)
	how = |name| if (redirected.contains(name)) "  ${name}, reached by a redirect" else "  ${name}, declared in Blueprint.roc"
	match Lock.new_hosts(before, after) {
		[] => ""
		added => "Blueprint.lock will name download hosts it did not name before:\n${Str.join_with(added.map(how), "\n")}"
	}
}

expect {
	entry = |urls, served| { name: "tool", system: "x86_64-linux", urls, sha256: "aa", size: 3, obtained: Computed, served, witness: "" }
	release = "https://github.com/o/r/releases/download/1/t"
	before = [entry([release], ["github.com"])]
	after = [entry([release, "https://mirror.example.test/t"], ["release-assets.githubusercontent.com"])]
	hosts_notice(before, after) == "Blueprint.lock will name download hosts it did not name before:\n  mirror.example.test, declared in Blueprint.roc\n  release-assets.githubusercontent.com, reached by a redirect"
		and hosts_notice([], before) == "Blueprint.lock will name download hosts it did not name before:\n  github.com, declared in Blueprint.roc"
		and hosts_notice(after, after) == ""
		and hosts_notice(after, before) == ""
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
	held = if (here) compiler_held!(what, program) else Err(NotHeld)
	downloaded : Try({ sha256 : Str, size : U64, bytes : List(U8), served : Str }, [NotDownloaded])
	downloaded = if held.is_err() and (here or looked.published.is_err()) {
		Ok(hashed!(what, program.urls).map_err(|message| FetchFailed(absent_advice(program, message)))?)
	} else {
		Err(NotDownloaded)
	}
	# Bytes the store already held were served by no host now.
	computed : Try(Lock.Hashed, [NotDownloaded])
	computed = match held {
		Ok(found) => Ok({ sha256: found.sha256, size: found.size, served: [] })
		Err(_) => downloaded.map_ok(|found| { sha256: found.sha256, size: found.size, served: [found.served] })
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

## The first of a program's URLs that serves it, tried in order, hashed, with
## the host that served the bytes after any redirect: what the update records
## of where they came from. The address that served them is not kept, only
## its host: a release host signs the address it redirects to.
hashed! : Str, List(Str) => Try({ sha256 : Str, size : U64, bytes : List(U8), served : Str }, Str)
hashed! = |what, urls| {
	var $failures = []
	for url in urls {
		_ = Stderr.line!("blueprint: fetching ${what} from ${url} to record its digest")
		match Download.served!(url) {
			Ok(answer) => return Ok({ sha256: Crypto.SHA256.hash(answer.bytes).to_hex(), size: answer.bytes.len(), bytes: answer.bytes, served: Lock.host(answer.url) })
			Err(reason) => {
				$failures = $failures.append("could not download ${what} from ${url}: ${reason}")
			}
		}
	}
	match $failures {
		[] => Err("${what} has no URL to download it from")
		[only] => Err(only)
		_ => Err("no URL of ${what} served it:\n  ${Str.join_with($failures, "\n  ")}")
	}
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
## a release asset: asked of the release's host, once for each release, and
## the address asked, which the lock keeps as the digest's witness. A
## release that cannot be asked about is said so once, and every download of
## it is then hashed here, as for a host that publishes nothing.
published! : Spec.Program, List(Asked) => { published : Try(Lock.Reported, [NotPublished]), asked : List(Asked) }
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
		Ok(Described(text)) => Published.digest(text, release.asset).map_ok(|found| { sha256: found.sha256, size: found.size, witness: release.api }).map_err(|_| NotPublished)
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
				.concat("blueprint includes Roc ${compiler_version.trim()}; ")
				.concat("set ROC to use another compatible executable:\n${message}")
		# A message that already names the command is not told it twice.
		LockFailed(message) => if (message.contains("blueprint update")) message else "${message}; use `blueprint update` to initialize or deliberately refresh pins"
		PlanFailed([problem]) => problem
		PlanFailed(problems) => "this cannot be carried out:\n  ${Str.join_with(problems, "\n  ")}"
		UnsafePath(value) => "refusing unsafe or symlinked runtime path: ${value}"
		Refused(message) => message
		BadSpec(InvalidSexpr(msg)) => "could not read the Spec from Blueprint.roc: ${msg}"
		BadSpec(UnsupportedFormat({ major, minor })) => "Spec format ${U64.to_str(major)}.${U64.to_str(minor)} is not supported by this blueprint (understands major ${Spec.current_format.major.to_str()}); upgrade blueprint or change the platform version"
		NeedsFeatures(missing) => "Blueprint.roc needs features: ${Str.join_with(missing, ", ")}; upgrade blueprint"
		InvalidProject(msg) => "invalid Spec project: ${msg}"
		RenderFailed(msg) => "cannot generate the ${provider} files: ${msg}"
		ActivationFailed(msg) => "cannot describe the environment: ${msg}"
		RocPackagesFailed(msg) => msg
		FetchFailed(msg) => msg
		StoreFailed(msg) => msg
		BadSpec(MissingRequiredField(field)) => "the Spec from Blueprint.roc is missing ${field}"
		BadExitStatus(Cmd.Output.{ command, status, stderr_bytes, .. }) =>
			"`${command}` failed (${Str.inspect(status)}):\n".concat(Str.from_utf8_lossy(stderr_bytes))
		TaskFailed(name, code) => "task ${name} exited with code ${code.to_str()}"
		UnknownTask(name, known) => "no task named \"${name}\"; Blueprint.roc defines: ${Str.join_with(known, ", ")}"
		UnknownShell(name, known) => "no shell named \"${name}\"; Blueprint.roc defines: ${Str.join_with(known, ", ")}"
		CommandFailed(argv, code) => "`${Str.join_with(argv, " ")}` exited with code ${code.to_str()}"
		other => Str.inspect(other)
	}

import "../fixtures/consumer/authority.lock" as lock_report_authority : Str

# The supported projection exposes exact locked Nix attributes, without
# registry resolution, while narrowing output to the names requested.
expect match Lock.parse(lock_report_authority) {
	Ok(lock) => match LockReport.render(lock, ["nixpkgs"], True, providers) {
		Ok(text) => {
			decoded : Try({ format : U64, sources : { nixpkgs : { content_identity : Str, metadata : { nix : { fetchTree : { rev : Str, narHash : Str, lastModified : U64, owner : Str } } } } }, fetched : List(Str) }, _)
			decoded = Json.parse(text)
			match decoded {
				Ok(read) => read.format == 2 and read.sources.nixpkgs.metadata.nix.fetchTree == { rev: "4975466d324710c576dc11ad614684e6bd8cad8e", narHash: "sha256-xJ+X4hBtOcAFGBOe5nAMyMUeF9foJBmIOu3NjBqBycU=", lastModified: 1790185690, owner: "NixOS" } and read.sources.nixpkgs.content_identity == "sha256:c49f97e2106d39c00518139ee6700cc8c51e17d7e82419883aedcd8c1a81c9c5" and read.fetched.is_empty() and !text.contains("roc-overlay")
				Err(_) => False
			}
		}
		Err(_) => False
	}
	Err(_) => False
}

# Updating another program, adding/removing tasks, and a future minor lock
# encoding leave a selected source and its content identity unchanged.
expect match Lock.parse(lock_report_authority) {
	Ok(lock) => {
		before = LockReport.render(lock, ["nixpkgs"], True, providers)
		future = match Lock.parse(lock.to_str().replace_each("(minor 1)", "(minor 9)")) {
			Ok(parsed) => LockReport.render(parsed, ["nixpkgs"], True, providers)
			Err(_) => Err("future minor did not parse")
		}
		program = { name: "roc-stable", system: "x86_64-linux", urls: ["https://example.test/roc"], sha256: "1111", size: 4, obtained: Computed, served: [], witness: "" }
		spec = Spec.empty("test")
		with_task = { ..spec, tasks: [{ name: "check", environment: "dev", run: ["check"] }] }
		Lock.intent_of(spec) == Lock.intent_of(with_task)
			and before.is_ok()
			and before == LockReport.render({ ..lock, fetched: [program] }, ["nixpkgs"], True, providers)
			and before == LockReport.render({ ..lock, fetched: [{ ..program, sha256: "2222" }] }, ["nixpkgs"], True, providers)
			and before == LockReport.render({ ..lock, intent: Lock.intent_of(with_task) }, ["nixpkgs"], True, providers)
			and before == LockReport.render({ ..lock, intent: Lock.intent_of(spec) }, ["nixpkgs"], True, providers)
			and before == future
	}
	Err(_) => False
}

expect match Lock.parse(lock_report_authority) {
	Ok(lock) => LockReport.render(lock, ["missing"], True, providers) == Err("unknown locked entry: missing")
		and LockReport.render(lock, ["nixpkgs"], False, providers).map_ok(|text| text.starts_with("source nixpkgs [nix]")) == Ok(True)
	Err(_) => False
}

# Updating a different remote source preserves the selected content_identity; changing
# that source's own NAR content changes it, with no graph-layout fingerprint.
expect {
	changed = |sri, hex| {
		text = lock_report_authority.replace_each(sri, "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=").replace_each(hex, "sha256:0000000000000000000000000000000000000000000000000000000000000000")
		match Lock.parse(text) {
			Ok(lock) => lock_pin_identity(lock)
			Err(_) => Err("invalid fixture")
		}
	}
	before = match Lock.parse(lock_report_authority) {
		Ok(lock) => lock_pin_identity(lock)
		Err(_) => Err("invalid fixture")
	}
	before.is_ok()
		and before == changed("sha256-fhatlsqelliHOfoT723TYQb8DzxSn698DpobgiARHIM=", "sha256:7e16ad96ca9e96588739fa13ef6dd36106fc0f3c529faf7c0e9a1b8220111c83")
		and before != changed("sha256-xJ+X4hBtOcAFGBOe5nAMyMUeF9foJBmIOu3NjBqBycU=", "sha256:c49f97e2106d39c00518139ee6700cc8c51e17d7e82419883aedcd8c1a81c9c5")
}

lock_pin_identity : Lock -> Try(Str, Str)
lock_pin_identity = |lock| {
	text = LockReport.render(lock, ["nixpkgs"], True, providers)?
	decoded : Try({ sources : { nixpkgs : { content_identity : Str } } }, _)
	decoded = Json.parse(text)
	decoded.map_ok(|read| read.sources.nixpkgs.content_identity).map_err(|_| "invalid inspector JSON")
}
