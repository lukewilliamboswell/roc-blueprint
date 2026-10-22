## An independent pure provider fixture: no concrete adapter or Nix protocol.
import core.Provider
import core.Spec
import core.Lock
import core.Layout
import core.Steps
import core.Realise
import core.Project
import core.Value
import core.BuildModel
import BuildReport
import LockReport

ProviderContractTest := [].{}

provider : Provider
provider = Provider.{
	validate_source: |_source| Ok({}),
	validate_tool: |_name| Ok({}),
	validate_executor: |executor| if (executor.source.is_empty()) Err("fixture executor requires a channel") else Ok({}),
	activation_argv: |step| Ok(step.argv.take_first(1).append("environment")),
	activation: |text| Ok({ path: [{ directory: text.trim(), origin: "guix" }], variables: [] }),
	validate_reference: |reference| if (reference.starts_with("path:") or reference.starts_with("https://")) Ok({}) else Err("fixture references are paths or https"),
	name: "guix",
	features: ["builds", "build-files"],
	realises: |source| source.name == "guix" and source.version == 1,
	render: |_spec| Ok([{ path: "channel.plan", contents: "reviewed channel" }]),
	inspect_lock: |_lock| Ok([{ name: "channel", content_identity: "guix:commit:abc", digest_kind: Unknown, metadata: [{ name: "commit", value: Value.Str("abc") }, { name: "settings", value: Value.Attrs([{ name: "substitutes", value: Value.Bool(False) }]) }] }]),
	preflight: |_spec, _request, _system, _layout| Ok({}),
	realise: |spec, request, _system, layout, _lock| {
		(action, argv, artifacts) = match request {
			Run(name, extra) => (Run(name), ["guix-fixture", "shell", "--"].concat(spec.tasks.first().map_ok(|task| task.run) ?? []).concat(extra), [])
			Shell(name) => (Shell(name), ["guix-fixture", "shell"], [])
			Generate => (Generate, [], [])
			Build(name) => {
				closure = Project.build_closure(spec, name).map_err(|message| Unrealisable(message))?
				(Build(name), ["guix-fixture", "build", name], closure.map(|build| { provider: "guix", name: build.name, installable: "plan:${build.name}", output: build.output, dependencies: build.needs }))
			}
			Workflow(_) => return Err(Unrealisable("expand workflow first"))
		}
		Ok(Steps.{ steps: [{ action, argv, artifacts, files: [{ path: "${layout.generated_root}/channel.plan", contents: Json.to_str({ files: spec.build_files, inputs: spec.source_files }) }], operations: spec.source_files.map(|source| SourceFile(source)) }] })
	},

	build_prepare_argv: |step| Ok(step.argv.append("--prepare")),
	build_prepared: |text| {
		wire : { recipe : Str, artifact : Str }
		wire = Json.parse(text).map_err(|_| "invalid fixture preparation")?
		Ok({ build_identity: wire.recipe, outputs: [{ name: "artifact", path: wire.artifact }] })
	},
	build_execute_argv: |step, _prepared, options| Ok(step.argv.append("--report").concat(if (options.rebuild) ["--verify-rebuild"] else [])),
	build_result: |text| {
		wire : { recipe : Str, artifact : Str }
		wire = Json.parse(text).map_err(|_| "invalid fixture result")?
		Ok({ build_identity: wire.recipe, outputs: [{ name: "artifact", path: wire.artifact }], metadata: [{ name: "substituted", value: Value.Bool(False) }, { name: "attempts", value: Value.Int(2) }] })
	},
	build_exclusions: |_spec, _layout| Ok([]),
	build_local_inputs: |_spec, _name, _layout, _lock| Ok([]),
	build_capabilities: ["builds", "build-files", "dependency-builds", "prepare"],
	build_guarantees: ["captured-declared-inputs"],
	build_inputs: |project, name| {
		selected = project.builds.find_first(|entry| entry.name == name).map_err(|_| "missing build")?
		Ok(["channel"].concat(selected.inputs))
	},
	build_sources: |_spec, _name| Ok(["channel", "archive"]),
	resolve: |_spec, _system, layout, _update| Ok({ present: [{ program: "guix-fixture", because: "resolve channel" }], files: [], locals: [], argv: ["guix-fixture", "describe", "--save", "${layout.generated_root}/channel.lock"], native_lock: "${layout.generated_root}/channel.lock" }),
	lock_from_native: |spec, _layout, native, _trees| Ok(Lock.{ format: Lock.current_format, intent: Lock.intent_of(spec), sources: [{ name: "channel", provider: "guix", ref: "https://example.test/channel.git", rev: "abc", digest: "guix:commit:abc" }], hints: [{ provider: "guix", value: Value.Str(native) }], fetched: [] }),
}

spec : Spec
spec = {
	..Spec.empty("independent"),
	requires_: ["explicit-sources", "builds", "build-files", "source-files"],
	systems: ["x86_64-linux"],
	sources: [{ name: "channel", provider: { name: "guix", version: 1, ref: "https://example.test/channel.git" } }],
	environments: [{ name: "producer", parents: [], tools: [{ source: "channel", name: "git@2.50" }], overlays: [] }],
	tasks: [{ name: "check", environment: "producer", run: ["git", "--version"] }],
	source_files: [{ name: "archive", url: "https://example.test/source.tar.gz", sha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }],
	executors: [{ name: "native", provider: "guix", source: "channel" }],
	build_executors: [{ build: "base", executor: "native" }, { build: "app", executor: "native" }],
	build_files: [{ build: "app", paths: ["recipe.roc"] }],
	builds: [
		{ name: "base", environment: "producer", inputs: ["archive"], needs: [], run: ["git", "--version"], output: "base" },
		{ name: "app", environment: "producer", inputs: [], needs: ["base"], run: ["git", "--version"], output: "artifact" },
	],
}

layout : Layout
layout = Layout.{ project_root: "/project", workspace: "/project/.blueprint", generated_root: "/project/.blueprint", lock_path: "/project/Blueprint.lock" }

locked : Try(Lock, Str)
locked = (provider.lock_from_native)(spec, layout, "own native format", []).map_ok(|lock| { ..lock, sources: lock.sources.concat(spec.source_files.map(Lock.file_pin)) })

expect {
	result = || {
		lock = locked?
		validated = Project.validate(spec)?
		steps = Realise.plan(validated, Build("app"), "x86_64-linux", layout, lock, [provider]).map_err(|_| "plan refused")?
		step = steps.steps.first().map_err(|_| "no step")?
		argv = (provider.build_execute_argv)(step, { build_identity: "fixture:prepared", outputs: [{ name: "artifact", path: "/fixture" }] }, { rebuild: True })?
		Ok(
			argv == ["guix-fixture", "build", "app", "--report", "--verify-rebuild"]
				and step.operations == spec.source_files.map(|source| SourceFile(source))
				and step.artifacts.map(|entry| (entry.name, entry.dependencies)) == [("base", []), ("app", ["base"])]
				and step.files.first().map_ok(|file| file.contents.contains("recipe.roc")) == Ok(True)
				and (provider.build_sources)(spec, "app") == Ok(["channel", "archive"]),
		)
	}
	result() == Ok(True)
}

expect {
	result = || {
		lock = locked?
		steps = Realise.plan(spec, Run("check", ["literal argument"]), "x86_64-linux", layout, lock, [provider]).map_err(|_| "plan refused")?
		needs = Realise.requirements(spec, "x86_64-linux", ["check"], [provider]).map_err(|_| "requirements refused")?
		resolution = (provider.resolve)(spec, "x86_64-linux", layout, All)?
		Ok(
			steps.steps.first().map_ok(|step| step.argv) == Ok(["guix-fixture", "shell", "--", "git", "--version", "literal argument"])
				and needs.providers == ["guix"] and resolution.argv.first() == Ok("guix-fixture") and lock.hint("guix") == Ok(Value.Str("own native format")),
		)
	}
	result() == Ok(True)
}

expect {
	result = || {
		built = (provider.build_result)("{\"recipe\":\"guix:recipe:123\",\"artifact\":\"/outputs/artifact\"}")?
		text = BuildReport.render("app", "x86_64-linux", provider.name, built, [])?
		decoded : { provider : Str, build_identity : Str, metadata : { guix : { substituted : Bool, attempts : I64 } }, outputs : List({ name : Str, path : Str }) }
		decoded = Json.parse(text).map_err(|_| "invalid public report")?
		Ok(decoded.provider == "guix" and decoded.build_identity == "guix:recipe:123" and decoded.metadata.guix == { substituted: False, attempts: 2 } and decoded.outputs == built.outputs and !text.contains("derivation"))
	}
	result() == Ok(True)
}

expect {
	result = || {
		text = LockReport.render(locked?, ["channel"], True, [provider])?
		decoded : { sources : { channel : { content_identity : Str, digestKind : Str, metadata : { guix : { commit : Str, settings : { substitutes : Bool } } } } } }
		decoded = Json.parse(text).map_err(|_| "invalid public lock report")?
		Ok(decoded.sources.channel.content_identity == "guix:commit:abc" and decoded.sources.channel.digestKind == "unknown" and decoded.sources.channel.metadata.guix == { commit: "abc", settings: { substitutes: False } } and !text.contains("fetchTree"))
	}
	result() == Ok(True)
}

# Unknown adapters retain their authoritative content identity without guessing its kind.
expect {
	result = || {
		text = LockReport.render(locked?, ["channel"], True, [])?
		Ok(text.contains("\"digestKind\":\"unknown\"") and text.contains("\"metadata\":{}") and text.contains("guix:commit:abc"))
	}
	result() == Ok(True)
}

# A provider's projection cannot hide duplicate keys or claim another source.
expect {
	result = || {
		lock = locked?
		pin = (provider.inspect_lock)(lock)?.first().map_err(|_| "missing projection")?
		duplicate = { ..provider, inspect_lock: |_lock| Ok([{ ..pin, metadata: [{ name: "nested", value: Value.Attrs([{ name: "same", value: Value.Int(1) }, { name: "same", value: Value.Int(2) }]) }] }]) }
		foreign = { ..provider, inspect_lock: |_lock| Ok([{ ..pin, name: "archive" }]) }
		ambiguous = { ..provider, inspect_lock: |_lock| Ok([pin, pin]) }
		Ok(
			LockReport.render(lock, [], True, [duplicate]) == Err("duplicate JSON key: same")
				and LockReport.render(lock, [], True, [foreign]) == Err("provider guix projected an unowned source: archive")
				and LockReport.render(lock, [], True, [ambiguous]) == Err("duplicate projected source: channel"),
		)
	}
	result() == Ok(True)
}

expect {
	bad = { build_identity: "opaque", outputs: [], metadata: [{ name: "x", value: Value.Int(1) }, { name: "x", value: Value.Int(2) }] }
	BuildReport.render("app", "x86_64-linux", "guix", bad, []) == Err("duplicate report metadata field: x")
}

# Registration does not send a selected request to an unrelated package source.
expect {
	unused = { ..provider, name: "unused", realises: |_source| False, preflight: |_spec, _request, _system, _layout| Err("unselected provider was called") }
	result = || {
		steps = Realise.plan(spec, Build("app"), "x86_64-linux", layout, locked?, [unused, provider]).map_err(|_| "selected request refused")?
		Ok(steps.steps.first().map_ok(|step| step.argv) == Ok(["guix-fixture", "build", "app"]))
	}
	result() == Ok(True)
}

expect {
	built = { build_identity: "opaque", outputs: [], metadata: [] }
	BuildReport.render("app", "x86_64-linux", "", built, []) == Err("build report has no provider identity")
		and BuildReport.render("app", "x86_64-linux", "guix", { ..built, build_identity: " " }, []) == Err("build report has no build identity")
}

# Dependency-only archive pins appear at the producer, never as direct app inputs.
expect {
	result = || {
		lock = locked?
		project = Project.validate(spec)?
		closure = Project.build_closure(project, "app")?
		capture = |pins| {
			var $nodes = []
			for selected in closure {
				inputs = (provider.build_inputs)(project, selected.name)?
				$nodes = $nodes.append(BuildModel.capture_node(project, selected, "x86_64-linux", [], inputs, pins)?)
			}
			Ok({ name: "app", system: "x86_64-linux", provider: "guix", nodes: $nodes })
		}
		before = capture(lock.sources)?
		after = capture(lock.sources.map(|source| if (source.name == "archive") { ..source, digest: "sha256:changed" } else source))?
		Ok(BuildModel.compare(before, after) == Ok([{ build: "base", dependency_path: ["app", "base"], kind: "input-changed", name: "archive" }]))
	}
	result() == Ok(True)
}
