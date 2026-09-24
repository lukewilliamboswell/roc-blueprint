# Pure semantic fixtures shared by authoritative-lock and executable-plan tests.
import ir.Ir
import ir.Layout

TestData :: [].{
	layout : Layout
	layout = Layout.{
		project_root: "/project",
		workspace: "/work",
		generated_root: "/generated",
		lock_path: "/authority/inputs.lock",
	}

	builder : Ir.Environment
	builder = {
		name: "builder",
		parents: [],
		tools: [{ source: "default", name: "python3" }],
		overlays: [],
	}

	library : Ir.Build
	library = {
		name: "library",
		environment: "builder",
		inputs: ["assets"],
		needs: [],
		run: ["python3", "build.py"],
		output: "dist/library",
	}

	application : Ir.Build
	application = {
		..library,
		name: "app",
		needs: ["library"],
		output: "dist/app",
		run: ["python3", "build.py", "", "two words", "line\nbreak", "$HOME"],
	}

	Data : {
		systems : List(Str),
		sources : List(Ir.Source),
		inputs : List(Ir.Input),
		environments : List(Ir.Environment),
		shells : List(Ir.Shell),
		tasks : List(Ir.Task),
		build_sources : List(Ir.BuildSource),
		builds : List(Ir.Build),
		requires_ : List(Str),
		raw : List(Ir.Raw),
		extensions : List(Ir.Extension),
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
		requires_: ["sources", "builds"],
		raw: [],
		extensions: [],
	}

	project : Data -> Ir
	project = |t| Ir.{
		format: Ir.current_format,
		name: "plan fixture",
		systems: t.systems,
		sources: t.sources,
		inputs: t.inputs,
		environments: t.environments,
		shells: t.shells,
		tasks: t.tasks,
		build_sources: t.build_sources,
		builds: t.builds,
		requires_: t.requires_,
		raw: t.raw,
		extensions: t.extensions,
	}
}
