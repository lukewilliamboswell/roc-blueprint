# Typed authoring values lower into the shared semantic project model.
import EnvName
import FlakeRef
import InputName
import ProgramName
import System
import TaskName
import Tool
import Val
import WorkflowName

## Pure settings that compose through ordinary Roc lists and functions.
Config :: [].{

	## Named sources describe provider intent, not host discovery. Omitting the
	## "default" source is equivalent to `Packages("default", Auto)`.
	## Overlay inputs apply only where an environment selects them.
	## `Custom` and `Raw` retain consumer-specific extension data.
	## `Fetch` declares a program by its command name and a recipe: a function
	## from a System, such as "x86_64-linux", to where the program is
	## downloaded from there (see `Download`). The recipe is asked once for
	## each declared System while the configuration is checked, and only its
	## answers reach the Spec. A name is declared once, and an environment has
	## the program where it selects it with `Programs`.
	Setting : [
		Name(Str),
		Systems(List(System)),
		Packages(InputName, PackageSource),
		Input(InputName, FlakeRef),
		Overlay(InputName, FlakeRef),
		Environment(EnvName, List(EnvironmentSetting)),
		Shell(EnvName, List(ShellSetting)),
		Task(TaskName, List(TaskSetting)),
		Source(InputName, FlakeRef),
		Build(InputName, List(BuildSetting)),
		Workflow(WorkflowName, List(WorkflowStep)),
		Custom(Str, Str, Val),
		Raw(Str, Str, Val),
		Fetch(ProgramName, (Str -> Download)),
	]

	## What a recipe answers for one System. `File(url)` is the program
	## itself. `Archive(url, format, path)` is an archive that is unpacked
	## whole, with the program at `path` inside it. `Mirrored(download, urls)`
	## is one of those two with alternate URLs for the same bytes, tried in
	## order after its own, as in
	## `Mirrored(File("https://example.org/tool"), ["https://mirror.example.net/tool"])`.
	## `Unavailable` says the program does not exist for that System, which is
	## an error only where a task needs it. `Invalid(message)` says the recipe
	## was given something it cannot use, such as a malformed version:
	## `roc check` reports the message, so a recipe never crashes. A URL is
	## `https://<host>/<path>` with no credentials, query or fragment, and is
	## given once; `Blueprint.lock` records the one SHA-256 of what they serve,
	## so an alternate need not be trusted.
	Download : [File(Str), Archive(Str, ArchiveFormat, Str), Mirrored(Primary, List(Str)), Unavailable, Invalid(Str)]

	## A download that has a URL, and so can have alternates.
	Primary : [File(Str), Archive(Str, ArchiveFormat, Str)]

	ArchiveFormat : [TarGz, TarXz, Zip]

	## Workflows reference declarations; argv contains literal extra arguments.
	WorkflowStep : [
		RunTask(TaskName, List(Str)),
		BuildArtifact(InputName),
		RunWorkflow(WorkflowName),
	]

	PackageSource : [Auto, From(Provider)]
	Provider : [NixPackages(FlakeRef), GuixPackages(Str)]

	## Tools and Overlays occur at most once. ToolsFor occurs at most once per
	## System. Extend inherits tools and overlays parent first; an omitted or
	## empty list does not clear inherited values. Command exposes one tool's
	## main program under another name and may repeat with distinct names; the
	## tool's own executables are not added. A child replaces an inherited
	## Command of the same name. ToolWith adds a tool built with options its
	## package takes, as names and values: data, never an expression. It may
	## repeat with distinct tools, a child replaces an inherited tool's
	## options, and a tool is either plain or configured, not both.
	## RocPackages occurs at most once and lists
	## released Roc bundle URLs to lock, so Roc programs in the environment
	## resolve them without downloading; an extending environment inherits them.
	## Programs occurs at most once and selects programs `Fetch` declares, by
	## name. Expect occurs at most once and names programs the machine must
	## already have on PATH: they are checked for, never installed, and no
	## version is asked of them. Both inherit parent first, and one name is
	## only one of a program, an expected tool and a Command.
	EnvironmentSetting : [Tools(List(Tool)), ToolsFor(System, List(Tool)), Command(Str, Tool), ToolWith(Tool, List((Str, Val))), RocPackages(List(Str)), Overlays(List(InputName)), Extend(EnvName), Programs(List(ProgramName)), Expect(List(ProgramName))]

	## A shell is an alias for exactly one environment.
	ShellSetting : [Use(EnvName)]

	## Tasks require exactly one Use and one nonempty argv Run.
	TaskSetting : [Use(EnvName), Run(List(Str))]

	## Builds require Use, Run and one relative Output. Optional Inputs select
	## locked non-flake Sources; Needs selects build artifacts, not task names.
	## Sources and artifacts remain separate read-only inputs, never merged.
	BuildSetting : [Use(EnvName), Inputs(List(InputName)), Needs(List(InputName)), Run(List(Str)), Output(Str)]
}
