import Sexpr
import Value

## Versioned semantic configuration, independent of provider selection or host.
## Major 2 replaces shell packages with reusable environments and source intent.
## Tool names remain provider-native strings, not translated package names.
## Parents are resolved by Project.validate, parent first with first-occurrence
## deduplication. Shells and tasks refer directly to environment identities.
## Missing optional top-level fields default to empty; unknown fields are ignored.
## Consumers must reject unknown required features before deriving effects.
Ir := {
	format : { major : U64, minor : U64 },
	name : Str,
	requires_ : List(Str),
	systems : List(Str),
	sources : List({ name : Str, provider : [Auto, NixPackages(Str), GuixPackages(Str)] }),
	inputs : List({ name : Str, url : Str, kind : [Overlay, Flake] }),
	environments : List({ name : Str, parents : List(Str), tools : List({ source : Str, name : Str }), overlays : List(Str) }),
	shells : List({ name : Str, environment : Str }),
	tasks : List({ name : Str, environment : Str, run : List(Str) }),
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
	Shell : { name : Str, environment : Str }
	Task : { name : Str, environment : Str, run : List(Str) }
	Extension : { kind : Str, name : Str, value : Value }
	Raw : { backend : Str, target : Str, value : Value }

	current_format : Format
	current_format = { major: 2, minor: 0 }

	empty : Str -> Ir
	empty = |name| Ir.{
		format: current_format,
		name,
		requires_: [],
		systems: [],
		sources: [],
		inputs: [],
		environments: [],
		shells: [],
		tasks: [],
		extensions: [],
		raw: [],
	}

	to_str : Ir -> Str
	to_str = |ir| Str.concat(Sexpr.to_str(ir), "\n")

	## Parse the version header before interpreting any version-specific records.
	parse : Str -> Try(Ir, [InvalidSexpr(Str), MissingRequiredField(Str), UnsupportedFormat(Format)])
	parse = |text| {
		header : { format : Format }
		header = Sexpr.parse(text)?
		if header.format.major != current_format.major {
			return Err(UnsupportedFormat(header.format))
		}
		wire : Wire
		wire = Sexpr.parse(text)?
		Ok(
			Ir.{
				format: wire.format,
				name: wire.name,
				requires_: wire.requires_ ?? [],
				systems: wire.systems ?? [],
				sources: wire.sources ?? [],
				inputs: wire.inputs ?? [],
				environments: wire.environments ?? [],
				shells: wire.shells ?? [],
				tasks: wire.tasks ?? [],
				extensions: wire.extensions ?? [],
				raw: wire.raw ?? [],
			},
		)
	}

	unsupported_features : Ir, List(Str) -> List(Str)
	unsupported_features = |ir, supported| ir.requires_.keep_if(|feature| !supported.contains(feature))
}

Wire : {
	format : Ir.Format,
	name : Str,
	requires_ : Try(List(Str), [Missing]),
	systems : Try(List(Str), [Missing]),
	sources : Try(List(Ir.Source), [Missing]),
	inputs : Try(List(Ir.Input), [Missing]),
	environments : Try(List(Ir.Environment), [Missing]),
	shells : Try(List(Ir.Shell), [Missing]),
	tasks : Try(List(Ir.Task), [Missing]),
	extensions : Try(List(Ir.Extension), [Missing]),
	raw : Try(List(Ir.Raw), [Missing]),
}

expect Ir.parse(Ir.empty("x").to_str()) == Ok(Ir.empty("x"))
expect Ir.parse("((format ((major 1) (minor 0))) (shells 42))") == Err(UnsupportedFormat({ major: 1, minor: 0 }))
expect Ir.parse("((format ((major 3) (minor 0))))") == Err(UnsupportedFormat({ major: 3, minor: 0 }))
expect Ir.parse("((format ((major 2) (minor 0))) (name \"x\"))") == Ok(Ir.empty("x"))
expect Ir.parse("((format ((major 2) (minor 0))))").is_err()
expect Ir.parse("((name \"x\"))").is_err()
expect match Ir.parse("((future (Tag 1)) (format ((major 2) (minor 99))) (name \"x\") (shells (((name \"s\") (environment \"dev\") (future 1)))))") {
	Ok(ir) => ir.format.minor == 99 and ir.shells == [{ name: "s", environment: "dev" }]
	Err(_) => False
}
