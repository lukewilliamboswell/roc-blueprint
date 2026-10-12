import cli.Path
import Process
import Published
import Script

## The Roc in the manual, compiled. A reader copies what the manual shows, so
## every `[source,roc]` block of `docs/*.adoc` and `docs/releases/*.adoc`, and
## the first program the Get started chapter includes, is given to `roc check`
## against the platform in this repository.
##
## What a block is decides how it is checked:
##
## * One that starts `app [` is a whole `Blueprint.roc`. Its platform, written
##   as a placeholder in the manual, becomes this repository's.
## * Any other is settings, as they stand inside `config`. They are put in a
##   `config` with a `Name`, the imports of the platform modules they use, and
##   the package source `nix` when they write a tool of it and do not declare
##   it, as every complete example in the manual declares it.
## * `[source,roc,snippet=refused]` is settings the compiler must refuse: the
##   manual shows a mistake and says what the compiler reports.
## * `[source,roc,snippet=unchecked]` is not compiled: a line of another kind
##   of program, settings of an earlier release, or settings that refer to
##   what another block declares. The count of these is printed.
DocSnippets := [].{
	Kind : [App, Settings, Refused, Unchecked]

	Snippet : { file : Str, line : U64, kind : Kind, text : Str }

	## What a block is, from the line that declares it and its text.
	kind_of : Str, Str -> Kind
	kind_of = |declared, text|
		if declared.contains("snippet=unchecked") {
			Unchecked
		} else if declared.contains("snippet=refused") {
			Refused
		} else if text.starts_with("app [") {
			App
		} else {
			Settings
		}

	## The Roc blocks of one AsciiDoc file, in order, each with the line its
	## text starts on.
	extract : Str, Str -> List(Snippet)
	extract = |file, source| {
		var $found = []
		var $open = Err(Closed)
		var $previous = ""
		var $number = 0
		for line in source.split_on("\n") {
			$number = $number + 1
			match $open {
				Ok(block) =>
					if line == "----" {
						text = Str.join_with(block.lines, "\n")
						$found = $found.append({ file, line: block.line, kind: kind_of(block.declared, text), text })
						$open = Err(Closed)
					} else {
						$open = Ok({ ..block, lines: block.lines.append(line) })
					}

				Err(_) =>
					if line == "----" and $previous.starts_with("[source,roc") {
						$open = Ok({ declared: $previous, line: $number + 1, lines: [] })
					}
			}
			$previous = line
		}
		$found
	}

	## The program `roc check` is given for a block, against the platform at
	## `platform_ref`.
	program : Str, Snippet -> Str
	program = |platform_ref, snippet|
		match snippet.kind {
			App => with_platform(platform_ref, snippet.text)
			_ => {
				modules = [("Recipes.", "Recipes"), ("Config.", "Config"), ("System ->", "System")].keep_if(|(use, _)| snippet.text.contains(use)).map(|(_, name)| "import pf.${name}\n")
				name = if snippet.text.contains("\tName(") or snippet.text.starts_with("Name(") [] else ["\tName(\"snippet\"),"]
				source = if snippet.text.contains("\"nix#") and !snippet.text.contains("Packages(\"nix\"") ["\tPackages(\"nix\", From(NixPackages(\"github:NixOS/nixpkgs/nixos-unstable\"))),"] else []
				settings = snippet.text.split_on("\n").map(|line| if line.is_empty() line else "\t${line}")
				"app [config] { pf: platform \"${platform_ref}\" }\n\n${Str.join_with(modules, "")}\nconfig = [\n${Str.join_with(name.concat(source).concat(settings), "\n")}\n]\n"
			}
		}

	## A whole program with its platform replaced: the first line's
	## `platform "..."`, whatever stands there.
	with_platform : Str, Str -> Str
	with_platform = |platform_ref, text|
		match text.split_first("platform \"") {
			Ok({ before, after }) =>
				match after.split_first("\"") {
					Ok({ after: rest, .. }) => "${before}platform \"${platform_ref}\"${rest}\n"
					Err(_) => text
				}

			Err(_) => text
		}

	## Why `roc check` did not do what the block requires, or "" if it did.
	problem : Snippet, Process.Outcome -> Str
	problem = |snippet, outcome| {
		place = "${snippet.file}:${snippet.line.to_str()}"
		match snippet.kind {
			Refused => if outcome.code == 0 "${place}: the manual says the compiler refuses this, and it was accepted" else ""
			_ => if outcome.code == 0 "" else "${place}: this block of the manual does not compile"
		}
	}

	## Check every block of the manual under `root`, in `work`.
	run! : { roc : Str, platform_ref : Str, root : Str, work : Str }, (List(Process.Job) => Try(List(Process.Outcome), _)) => Try({}, _)
	run! = |options, drive!| {
		var $snippets = extract(Published.snippet_file, Published.snippet("<the platform URL of the latest release>"))
		for directory in ["docs", "docs/releases"] {
			for name in adoc_files!("${options.root}/${directory}")? {
				$snippets = $snippets.concat(extract("${directory}/${name}", Path.read_utf8!(Path.utf8("${options.root}/${directory}/${name}"))?))
			}
		}
		compiled = $snippets.keep_if(|snippet| snippet.kind != Unchecked)
		if compiled.is_empty() {
			return Script.fail!("the manual holds no Roc to compile under ${options.root}/docs")
		}
		Path.create_all!(Path.utf8(options.work))?
		var $jobs = []
		for snippet in compiled {
			name = "Snippet${$jobs.len().to_str()}.roc"
			Path.write_utf8!(Path.utf8("${options.work}/${name}"), program(options.platform_ref, snippet))?
			$jobs = $jobs.append(Process.command(options.roc, ["check", name], options.work))
		}
		outcomes = drive!($jobs)?
		var $at = 0
		for snippet in compiled {
			outcome = outcomes.get($at) ?? { code: -1, stdout: "", stderr: "" }
			$at = $at + 1
			reason = problem(snippet, outcome)
			if !reason.is_empty() {
				return Script.fail!("${program(options.platform_ref, snippet)}\n${outcome.stdout}${outcome.stderr}\n${reason}")
			}
		}
		count = |kind| $snippets.keep_if(|snippet| snippet.kind == kind).len().to_str()
		Script.info!("   ", "the manual's Roc: ${count(App)} whole programs and ${count(Settings)} blocks of settings compile, ${count(Refused)} shown as mistakes are refused, ${count(Unchecked)} are not compiled")
	}
}

adoc_files! : Str => Try(List(Str), _)
adoc_files! = |directory| {
	var $names = []
	for entry in Path.list!(Path.utf8(directory))? {
		name = Path.to_str(entry)?.split_on("/").last() ?? ""
		if name.ends_with(".adoc") and (Path.is_file!(entry) ?? False) {
			$names = $names.append(name)
		}
	}
	Ok(Process.sorted($names))
}

chapter : Str
chapter = "= Chapter\n\n[source,roc]\n----\napp [config] { pf: platform \"<the platform URL of a release>\" }\n\nconfig = [Name(\"x\")]\n----\n\nText.\n\n[source,roc]\n----\nPrograms([Fetch(\"tool\", Recipes.file(\"https://example.org/tool-{system}\"))]),\nTools([\"nix#git\"]),\n----\n\n[source,sh]\n----\nblueprint check\n----\n\n[source,roc,snippet=refused]\n----\nTools([\"git\"]),\n----\n\n[source,roc,snippet=unchecked]\n----\ncore: \"{core-url}\"\n----\n\n----\nnot Roc\n----\n"

# Only Roc blocks are found, each with its kind and the line its text is on.
expect DocSnippets.extract("docs/c.adoc", chapter).map(|snippet| (snippet.line, snippet.kind)) == [(5, App), (14, Settings), (25, Refused), (30, Unchecked)]
expect DocSnippets.extract("docs/c.adoc", chapter).map(|snippet| snippet.text).get(1) == Ok("Programs([Fetch(\"tool\", Recipes.file(\"https://example.org/tool-{system}\"))]),\nTools([\"nix#git\"]),")
expect DocSnippets.extract("docs/c.adoc", "[source,roc]\n----\nnever closed\n") == []

# A whole program keeps everything but its platform.
expect DocSnippets.program("../pf/main.roc", { file: "f", line: 1, kind: App, text: "app [config] { pf: platform \"{platform-url}\" }\n\nconfig = [Name(\"x\")]" }) == "app [config] { pf: platform \"../pf/main.roc\" }\n\nconfig = [Name(\"x\")]\n"

# Settings get a config, a name, the modules they use and the source `nix`
# when they write a tool of it without declaring it.
expect DocSnippets.program("../pf/main.roc", { file: "f", line: 1, kind: Settings, text: "Programs([Fetch(\"tool\", Recipes.file(\"https://example.org/tool-{system}\"))]),\nEnvironment(\"dev\", [\n\tTools([\"nix#git\"]),\n])," })
	== "app [config] { pf: platform \"../pf/main.roc\" }\n\nimport pf.Recipes\n\nconfig = [\n\tName(\"snippet\"),\n\tPackages(\"nix\", From(NixPackages(\"github:NixOS/nixpkgs/nixos-unstable\"))),\n\tPrograms([Fetch(\"tool\", Recipes.file(\"https://example.org/tool-{system}\"))]),\n\tEnvironment(\"dev\", [\n\t\tTools([\"nix#git\"]),\n\t]),\n]\n"
expect {
	declared = DocSnippets.program("p", { file: "f", line: 1, kind: Settings, text: "Name(\"mine\"),\nPackages(\"nix\", From(NixPackages(\"github:NixOS/nixpkgs/nixos-25.05\"))),\nEnvironment(\"dev\", [Tools([\"nix#git\"])])," })
	!declared.contains("Name(\"snippet\")") and !declared.contains("nixos-unstable")
}

# A block that must compile and does not, and one that must not and does.
expect DocSnippets.problem({ file: "docs/c.adoc", line: 14, kind: Settings, text: "" }, { code: 1, stdout: "", stderr: "" }) == "docs/c.adoc:14: this block of the manual does not compile"
expect DocSnippets.problem({ file: "docs/c.adoc", line: 25, kind: Refused, text: "" }, { code: 0, stdout: "", stderr: "" }) == "docs/c.adoc:25: the manual says the compiler refuses this, and it was accepted"
expect DocSnippets.problem({ file: "f", line: 1, kind: App, text: "" }, { code: 0, stdout: "", stderr: "" }) == "" and DocSnippets.problem({ file: "f", line: 1, kind: Refused, text: "" }, { code: 1, stdout: "", stderr: "" }) == ""
