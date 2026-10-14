# Canonical configuration data and its versioned, optional-field wire codec.
import Sexpr
import Value

## Versioned semantic configuration, independent of provider selection or host.
## Major 2 replaces shell packages with reusable environments and source intent.
## Tool names remain provider-native strings, not translated package names.
## Parents are resolved by Project.validate, parent first with first-occurrence
## deduplication. Shells and tasks refer directly to environment identities.
## Missing optional top-level fields default to empty; unknown fields are ignored.
## Consumers must reject unknown required features before deriving effects.
Spec := {
	format : { major : U64, minor : U64 },
	name : Str,
	requires_ : List(Str),
	systems : List(Str),
	sources : List({ name : Str, provider : [Auto, NixPackages(Str), GuixPackages(Str)] }),
	inputs : List({ name : Str, url : Str, kind : [Overlay, Flake] }),
	environments : List({ name : Str, parents : List(Str), tools : List({ source : Str, name : Str }), overlays : List(Str) }),
	system_tools : List({ environment : Str, system : Str, tools : List({ source : Str, name : Str }) }),
	commands : List({ environment : Str, name : Str, tool : { source : Str, name : Str } }),
	configured_tools : List({ environment : Str, tool : { source : Str, name : Str }, options : Value }),
	roc_packages : List({ environment : Str, name : Str, source : Str }),
	programs : List({ name : Str, system : Str, urls : List(Str), unpack : [File, TarGz, TarXz, Zip], path : Str }),
	environment_programs : List({ environment : Str, programs : List(Str) }),
	expects : List({ environment : Str, programs : List(Str) }),
	shells : List({ name : Str, environment : Str }),
	tasks : List({ name : Str, environment : Str, run : List(Str) }),
	build_sources : List({ name : Str, ref : Str }),
	builds : List({ name : Str, environment : Str, inputs : List(Str), needs : List(Str), run : List(Str), output : Str }),
	workflows : List(
		{
			name : Str,
			steps : List(
				[
					RunTask(Str, List(Str)),
					BuildArtifact(Str),
					RunWorkflow(Str),
				],
			),
		},
	),
	extensions : List({ kind : Str, name : Str, value : Value }),
	raw : List({ backend : Str, target : Str, value : Value }),
}.{
	is_eq : _
	encoder_for : _

	Format : { major : U64, minor : U64 }

	## Which package set a source is. `Auto` is read and never written: a
	## Spec or a Lock from before sources were explicit holds it, and
	## `Project.validate` refuses a Spec that does.
	Provider : [Auto, NixPackages(Str), GuixPackages(Str)]
	Source : { name : Str, provider : Provider }
	Input : { name : Str, url : Str, kind : [Overlay, Flake] }
	Tool : { source : Str, name : Str }
	Environment : { name : Str, parents : List(Str), tools : List(Tool), overlays : List(Str) }
	SystemTools : { environment : Str, system : Str, tools : List(Tool) }

	## One tool's main program under another command name. The environment
	## receives only that command, not the tool's own executables.
	Command : { environment : Str, name : Str, tool : Tool }

	## A tool built with options its package takes, such as a toolchain's
	## targets. `options` is data the provider passes to the package, never an
	## expression. The environment receives the tool as it would a plain one.
	ConfiguredTool : { environment : Str, tool : Tool, options : Value }

	## A released Roc package bundle the environment's Roc programs resolve
	## without a download. `name` is its content hash, the directory Roc looks
	## for in its package cache; `source` names the locked build source that
	## fetches it.
	RocPackage : { environment : Str, name : Str, source : Str }

	## What a download is: `File` is the program itself; the others are an
	## archive to unpack whole, of which the program is one file.
	Unpack : [File, TarGz, TarXz, Zip]

	## A program downloaded for one System, under the command name `name`.
	## There is one entry per System it exists for: a program with no entry
	## for a System is unavailable there. `urls` is where the download is, the
	## primary first and then alternates for the same bytes, each once; it is
	## never empty. `path` is the program inside the unpacked archive, and
	## empty for a `File`. The Lock holds the one SHA-256 of what every URL
	## serves; the Spec never does. A Spec that declares or selects a program
	## requires the feature `programs`.
	Program : { name : Str, system : Str, urls : List(Str), unpack : Unpack, path : Str }

	## The declared programs an environment has on PATH, by name.
	EnvironmentPrograms : { environment : Str, programs : List(Str) }

	## Programs an environment's commands expect the machine to have on PATH
	## already. They are checked for, never installed and never version-pinned.
	## A Spec that holds any requires the feature `expects`.
	Expects : { environment : Str, programs : List(Str) }
	Shell : { name : Str, environment : Str }
	Task : { name : Str, environment : Str, run : List(Str) }

	## Non-flake locked inputs, distinct from package-provider sources.
	BuildSource : { name : Str, ref : Str }

	## Run is exact argv. Output is a relative file or directory path; dependencies
	## expose only that artifact, separately from the writable project snapshot.
	Build : { name : Str, environment : Str, inputs : List(Str), needs : List(Str), run : List(Str), output : Str }

	## Ordered declarations, not command strings or executor recipes.
	Workflow : { name : Str, steps : List(WorkflowStep) }
	WorkflowStep : [RunTask(Str, List(Str)), BuildArtifact(Str), RunWorkflow(Str)]

	## Expansion retains repetitions and extra argv without shell parsing.
	AtomicStep : [RunTask(Str, List(Str)), BuildArtifact(Str)]

	Extension : { kind : Str, name : Str, value : Value }
	Raw : { backend : Str, target : Str, value : Value }

	current_format : Format
	current_format = { major: 2, minor: 7 }

	empty : Str -> Spec
	empty = |name| Spec.{
		format: current_format,
		name,
		requires_: [],
		systems: [],
		sources: [],
		inputs: [],
		environments: [],
		system_tools: [],
		commands: [],
		configured_tools: [],
		roc_packages: [],
		programs: [],
		environment_programs: [],
		expects: [],
		shells: [],
		tasks: [],
		build_sources: [],
		builds: [],
		workflows: [],
		extensions: [],
		raw: [],
	}

	to_str : Spec -> Str
	to_str = |spec| Str.concat(Sexpr.to_str(spec), "\n")

	## Parse the version header before interpreting any version-specific records.
	parse : Str -> Try(Spec, [InvalidSexpr(Str), MissingRequiredField(Str), UnsupportedFormat(Format)])
	parse = |text| {
		header : { format : Format }
		header = Sexpr.parse(text)?
		if header.format.major != current_format.major {
			return Err(UnsupportedFormat(header.format))
		}
		wire : Wire
		wire = Sexpr.parse(text)?
		Ok(
			Spec.{
				format: wire.format,
				name: wire.name,
				requires_: wire.requires_ ?? [],
				systems: wire.systems ?? [],
				sources: wire.sources ?? [],
				inputs: wire.inputs ?? [],
				environments: wire.environments ?? [],
				system_tools: wire.system_tools ?? [],
				commands: wire.commands ?? [],
				configured_tools: wire.configured_tools ?? [],
				roc_packages: wire.roc_packages ?? [],
				programs: wire.programs ?? [],
				environment_programs: wire.environment_programs ?? [],
				expects: wire.expects ?? [],
				shells: wire.shells ?? [],
				tasks: wire.tasks ?? [],
				build_sources: wire.build_sources ?? [],
				builds: wire.builds ?? [],
				workflows: wire.workflows ?? [],
				extensions: wire.extensions ?? [],
				raw: wire.raw ?? [],
			},
		)
	}

	unsupported_features : Spec, List(Str) -> List(Str)
	unsupported_features = |spec, supported| spec.requires_.keep_if(|feature| !supported.contains(feature))
}

Wire : {
	format : Spec.Format,
	name : Str,
	requires_ : Try(List(Str), [Missing]),
	systems : Try(List(Str), [Missing]),
	sources : Try(List(Spec.Source), [Missing]),
	inputs : Try(List(Spec.Input), [Missing]),
	environments : Try(List(Spec.Environment), [Missing]),
	system_tools : Try(List(Spec.SystemTools), [Missing]),
	commands : Try(List(Spec.Command), [Missing]),
	configured_tools : Try(List(Spec.ConfiguredTool), [Missing]),
	roc_packages : Try(List(Spec.RocPackage), [Missing]),
	programs : Try(List(Spec.Program), [Missing]),
	environment_programs : Try(List(Spec.EnvironmentPrograms), [Missing]),
	expects : Try(List(Spec.Expects), [Missing]),
	shells : Try(List(Spec.Shell), [Missing]),
	tasks : Try(List(Spec.Task), [Missing]),
	build_sources : Try(List(Spec.BuildSource), [Missing]),
	builds : Try(List(Spec.Build), [Missing]),
	workflows : Try(List(Spec.Workflow), [Missing]),
	extensions : Try(List(Spec.Extension), [Missing]),
	raw : Try(List(Spec.Raw), [Missing]),
}

expect Spec.parse(Spec.empty("x").to_str()) == Ok(Spec.empty("x"))

expect {
	spec = { ..Spec.empty("x"), requires_: ["system-tools"], system_tools: [{ environment: "dev", system: "x86_64-linux", tools: [{ source: "default", name: "wayland" }] }] }
	Spec.parse(spec.to_str()) == Ok(spec)
}

expect {
	spec = { ..Spec.empty("x"), requires_: ["commands"], commands: [{ environment: "dev", name: "roc-stable", tool: { source: "default", name: "rocpkgs.nightly" } }] }
	Spec.parse(spec.to_str()) == Ok(spec)
}

expect {
	spec = { ..Spec.empty("x"), requires_: ["sources", "roc-packages"], build_sources: [{ name: "roc-abc", ref: "tarball+https://example.test/abc.tar.zst" }], roc_packages: [{ environment: "dev", name: "abc", source: "roc-abc" }] }
	Spec.parse(spec.to_str()) == Ok(spec)
}

expect {
	options = Value.Attrs([{ name: "targets", value: Value.List([Value.Str("x86_64-unknown-linux-musl")]) }])
	spec = { ..Spec.empty("x"), requires_: ["configured-tools"], configured_tools: [{ environment: "dev", tool: { source: "default", name: "rust-bin.stable.\"1.95.0\".default" }, options }] }
	Spec.parse(spec.to_str()) == Ok(spec)
}

# A 2.5 record has no configured tools.
expect Spec.parse("((format ((major 2) (minor 5))) (name \"x\"))").map_ok(|spec| spec.configured_tools) == Ok([])

# Fetched programs, one entry per System, with what selects and expects them.
expect {
	spec = {
		..Spec.empty("x"),
		requires_: ["programs", "expects"],
		programs: [
			{ name: "roc-stable", system: "x86_64-linux", urls: ["https://example.test/roc-linux.tar.gz"], unpack: TarGz, path: "roc/roc" },
			{ name: "roc-stable", system: "x86_64-windows", urls: ["https://example.test/roc-windows.zip"], unpack: Zip, path: "roc/roc.exe" },
			{ name: "notes", system: "x86_64-linux", urls: ["https://example.test/notes.tar.xz", "https://mirror.example.test/notes.tar.xz"], unpack: TarXz, path: "bin/notes" },
			{ name: "tool", system: "x86_64-linux", urls: ["https://example.test/tool-x86_64-linux"], unpack: File, path: "" },
		],
		environment_programs: [{ environment: "dev", programs: ["roc-stable", "tool"] }],
		expects: [{ environment: "dev", programs: ["gh", "git"] }],
	}
	Spec.parse(spec.to_str()) == Ok(spec) and Spec.current_format == { major: 2, minor: 7 }
}

# A 2.6 record, as blueprint 0.5 printed it, has none of them.
expect match Spec.parse("((format ((major 2) (minor 6))) (name \"x\") (requires (\"commands\")) (commands (((environment \"dev\") (name \"roc-stable\") (tool ((source \"default\") (name \"rocpkgs.nightly\")))))))") {
	Ok(spec) => spec.format == { major: 2, minor: 6 } and spec.programs == [] and spec.environment_programs == [] and spec.expects == [] and spec.commands.len() == 1
	Err(_) => False
}

# A consumer that predates them refuses the Spec by the features' names.
expect match Spec.parse("((format ((major 2) (minor 7))) (name \"x\") (requires (\"programs\" \"expects\")))") {
	Ok(spec) => Spec.unsupported_features(spec, ["raw", "sources", "commands"]) == ["programs", "expects"]
	Err(_) => False
}

# An unpacking the consumer does not know is not dropped as optional data.
expect Spec.parse("((format ((major 2) (minor 7))) (name \"x\") (programs (((name \"a\") (system \"x86_64-linux\") (urls (\"https://example.test/a.7z\")) (unpack SevenZip) (path \"a\")))))").is_err()
expect Spec.parse("((format ((major 2) (minor 7))) (name \"x\") (programs (((name \"a\") (system \"x86_64-linux\") (unpack File) (path \"\")))))").is_err()
expect Spec.parse("((format ((major 1) (minor 0))) (shells 42))") == Err(UnsupportedFormat({ major: 1, minor: 0 }))
expect Spec.parse("((format ((major 3) (minor 0))))") == Err(UnsupportedFormat({ major: 3, minor: 0 }))
# Earlier minor records omit newer optional build and workflow fields.
expect match Spec.parse("((format ((major 2) (minor 0))) (name \"x\"))") {
	Ok(spec) => spec.format == { major: 2, minor: 0 } and
		spec.build_sources.is_empty() and spec.builds.is_empty() and
			spec.workflows.is_empty()
	Err(_) => False
}
expect Spec.parse("((format ((major 2) (minor 0))))").is_err()
expect Spec.parse("((name \"x\"))").is_err()
expect Spec.parse("((format ((major 2) (minor 1))) (name \"x\") (build_sources (((name \"assets\")))))").is_err()
expect Spec.parse("((format ((major 2) (minor 1))) (name \"x\") (builds (((name \"app\") (environment \"dev\") (inputs ()) (needs ()) (run (\"true\"))))))").is_err()
expect match Spec.parse("((format ((major 2) (minor 99))) (name \"x\") (requires (\"sources\" \"builds\" \"future\")))") {
	Ok(spec) => Spec.unsupported_features(spec, ["sources", "builds"]) == ["future"] and Spec.unsupported_features(spec, []) == ["sources", "builds", "future"]
	Err(_) => False
}
expect match Spec.parse("((future (Tag 1)) (format ((major 2) (minor 99))) (name \"x\") (shells (((name \"s\") (environment \"dev\") (future 1)))))") {
	Ok(spec) => spec.format.minor == 99 and spec.shells == [{ name: "s", environment: "dev" }]
	Err(_) => False
}

# An older consumer must reject workflows via the required-feature marker.
expect match Spec.parse(
	\\((format ((major 2) (minor 2))) (name "x")
	\\ (requires ("workflows")) (workflows (((name "ci") (steps ())))))
	,
) {
	Ok(spec) => spec.workflows == [{ name: "ci", steps: [] }] and
		Spec.unsupported_features(spec, ["sources", "builds"]) == ["workflows"]
	Err(_) => False
}

# Omitted workflow fields remain compatible with both earlier minor versions.
expect ["0", "1"].all(
	|minor|
		match Spec.parse("((format ((major 2) (minor ${minor}))) (name \"x\"))") {
			Ok(spec) => spec.workflows == []
			Err(_) => False
		},
)

# Unknown step tags cannot be silently dropped as optional top-level data.
expect Spec.parse(
	\\((format ((major 2) (minor 2))) (name "x")
	\\ (workflows (((name "ci") (steps ((FutureStep "check")))))))
	,
).is_err()

# Task extra argv is required in every RunTask record on the wire.
expect Spec.parse(
	\\((format ((major 2) (minor 2))) (name "x")
	\\ (workflows (((name "ci") (steps ((RunTask "check")))))))
	,
).is_err()

# A workflow must contain a typed steps list, even when intentionally empty.
expect Spec.parse(
	\\((format ((major 2) (minor 2))) (name "x")
	\\ (workflows (((name "ci")))))
	,
).is_err()

# A 2.7 program entry names its URLs as a list; one bare `url` is not it.
expect Spec.parse("((format ((major 2) (minor 7))) (name \"x\") (programs (((name \"a\") (system \"x86_64-linux\") (url \"https://example.test/a\") (unpack File) (path \"\")))))").is_err()
expect Spec.parse("((format ((major 2) (minor 7))) (name \"x\") (programs (((name \"a\") (system \"x86_64-linux\") (urls (\"https://example.test/a\" \"https://mirror.example.test/a\")) (unpack File) (path \"\")))))").map_ok(|spec| spec.programs.map(|program| program.urls)) == Ok([["https://example.test/a", "https://mirror.example.test/a"]])
