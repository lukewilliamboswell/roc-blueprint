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
	Provider : [Auto, NixPackages(Str), GuixPackages(Str)]
	Source : { name : Str, provider : Provider }
	Input : { name : Str, url : Str, kind : [Overlay, Flake] }
	Tool : { source : Str, name : Str }
	Environment : { name : Str, parents : List(Str), tools : List(Tool), overlays : List(Str) }
	SystemTools : { environment : Str, system : Str, tools : List(Tool) }
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
	current_format = { major: 2, minor: 3 }

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
	Spec.parse(spec.to_str()) == Ok(spec) and Spec.current_format == { major: 2, minor: 3 }
}
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
