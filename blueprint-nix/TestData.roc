# Pure semantic fixtures shared by authoritative-lock and executable-plan tests.
import core.Spec
import core.Layout

TestData :: [].{
	layout : Layout
	layout = Layout.{
		project_root: "/project",
		workspace: "/work",
		generated_root: "/generated",
		lock_path: "/authority/inputs.lock",
	}

	builder : Spec.Environment
	builder = {
		name: "builder",
		parents: [],
		tools: [{ source: "default", name: "python3" }],
		overlays: [],
	}

	library : Spec.Build
	library = {
		name: "library",
		environment: "builder",
		inputs: ["assets"],
		needs: [],
		run: ["python3", "build.py"],
		output: "dist/library",
	}

	application : Spec.Build
	application = {
		..library,
		name: "app",
		needs: ["library"],
		output: "dist/app",
		run: ["python3", "build.py", "", "two words", "line\nbreak", "$HOME"],
	}

	Data : {
		systems : List(Str),
		sources : List(Spec.Source),
		inputs : List(Spec.Input),
		environments : List(Spec.Environment),
		shells : List(Spec.Shell),
		tasks : List(Spec.Task),
		build_sources : List(Spec.BuildSource),
		builds : List(Spec.Build),
		workflows : List(Spec.Workflow),
		requires_ : List(Str),
		raw : List(Spec.Raw),
		extensions : List(Spec.Extension),
	}

	data : Data
	data = {
		systems: ["x86_64-linux"],
		sources: [],
		inputs: [],
		environments: [builder],
		shells: [{ name: "default", environment: "builder" }],
		tasks: [
			{
				name: "check",
				environment: "builder",
				run: ["python3", "check.py", "configured argument"],
			},
		],
		build_sources: [{ name: "assets", ref: "path:./assets" }],
		builds: [application, library],
		workflows: [],
		requires_: ["sources", "builds"],
		raw: [],
		extensions: [],
	}

	# Repeated nested runs and diamond builds retain explicit operation identity.
	workflow_data : Data
	workflow_data = {
		..data,
		requires_: ["sources", "builds", "workflows"],
		builds: [
			{ ..application, name: "bundle", needs: ["app", "other"] },
			application,
			{ ..application, name: "other" },
			library,
		],
		workflows: [
			{
				name: "ci",
				steps: [
					BuildArtifact("library"),
					RunTask("check", ["", "two words", "--literal", "a\nb", "$HOME"]),
					RunWorkflow("verify"),
					RunWorkflow("verify"),
					BuildArtifact("bundle"),
				],
			},
			{
				name: "verify",
				steps: [RunTask("check", []), BuildArtifact("bundle")],
			},
			{ name: "empty", steps: [] },
			{ name: "nothing", steps: [RunWorkflow("empty")] },
			{ name: "one", steps: [RunTask("check", [])] },
		],
	}

	project : Data -> Spec
	project = |t| Spec.{
		format: Spec.current_format,
		name: "plan fixture",
		systems: t.systems,
		sources: t.sources,
		inputs: t.inputs,
		environments: t.environments,
		shells: t.shells,
		tasks: t.tasks,
		build_sources: t.build_sources,
		builds: t.builds,
		workflows: t.workflows,
		requires_: t.requires_,
		raw: t.raw,
		extensions: t.extensions,
	}
}
