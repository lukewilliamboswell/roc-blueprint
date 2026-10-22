## What entering an environment means, as data: directories to put first on
## the search path and variables to set, each naming what supplies it. The
## core produces it for what it realises itself, a provider for what it
## realises, and a presenter renders it at the edge. No stage before Present
## produces shell text.
import JsonData

Activation := { path : List(Entry), variables : List(Variable) }.{
	is_eq : _

	## A directory for the search path, from the program, package source or
	## provider that supplies it.
	Entry : { directory : Str, origin : Str }

	## A variable to export, from what sets it.
	Variable : { name : Str, value : Str, origin : Str }

	empty : Activation
	empty = Activation.{ path: [], variables: [] }

	## `first` ahead of `second` on the search path; a variable both set
	## takes `second`'s value, as a later export would.
	merge : Activation, Activation -> Activation
	merge = |first, second| {
		kept = first.variables.keep_if(|variable| !second.variables.any(|later| later.name == variable.name))
		Activation.{ path: first.path.concat(second.path.keep_if(|entry| !first.path.any(|known| known.directory == entry.directory))), variables: kept.concat(second.variables) }
	}

	## Every directory, first on the search path first.
	directories : Activation -> List(Str)
	directories = |activation| activation.path.map(|entry| entry.directory)

	## The directories ahead of an existing search path, joined with its
	## separator.
	search_path : Activation, Str, Str -> Str
	search_path = |activation, existing, separator| {
		ahead = Str.join_with(directories(activation), separator)
		if existing.is_empty() {
			ahead
		} else if ahead.is_empty() {
			existing
		} else {
			"${ahead}${separator}${existing}"
		}
	}

	## POSIX shell lines a caller can `eval`: each value is single-quoted,
	## so nothing in it is expanded, and a quote in it is closed, escaped and
	## reopened. PATH is prepended to the caller's own.
	shell : Activation -> Str
	shell = |activation| {
		lines = (if (activation.path.is_empty()) [] else ["export PATH=${quoted(Str.join_with(directories(activation), ":"))}:\"$PATH\""])
			.concat(activation.variables.map(|variable| "export ${variable.name}=${quoted(variable.value)}"))
		Str.join_with(lines.map(|line| "${line}\n"), "")
	}

	quoted : Str -> Str
	quoted = |value| "'${value.replace_each("'", "'\\''")}'"

	## What a GitHub Actions step appends to `$GITHUB_PATH` and `$GITHUB_ENV`:
	## one directory per line, and `name=value` for a value without a line
	## break. A value with one uses the heredoc form the runner documents.
	github : Activation -> { path : Str, env : Str }
	github = |activation| {
		env = activation.variables.map(
			|variable|
				if variable.value.contains("\n") {
					"${variable.name}<<BLUEPRINT_EOF\n${variable.value}\nBLUEPRINT_EOF\n"
				} else {
					"${variable.name}=${variable.value}\n"
				},
		)
		{ path: Str.join_with(directories(activation).map(|directory| "${directory}\n"), ""), env: Str.join_with(env, "") }
	}

	## A JSON rendering for an editor or agent: a report, never authority.
	to_json : Activation -> Try(Str, Str)
	to_json = |activation| JsonData.encode(
		JsonData.Object([
			{ name: "format", value: JsonData.Number("1") },
			{ name: "path", value: JsonData.Array(activation.path.map(|entry| JsonData.Object([{ name: "directory", value: JsonData.String(entry.directory) }, { name: "origin", value: JsonData.String(entry.origin) }]))) },
			{ name: "variables", value: JsonData.Array(activation.variables.map(|variable| JsonData.Object([{ name: "name", value: JsonData.String(variable.name) }, { name: "value", value: JsonData.String(variable.value) }, { name: "origin", value: JsonData.String(variable.origin) }]))) },
		]),
	).map_err(JsonData.message)

	## A variable name a shell can export.
	valid_name : Str -> Bool
	valid_name = |name| {
		bytes = name.to_utf8()
		!bytes.is_empty()
			and !(bytes.first().map_ok(|b| b >= '0' and b <= '9') ?? True)
			and bytes.all(|b| (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or b == '_')
	}
}

sample : Activation
sample = Activation.{
	path: [{ directory: "/store/bin", origin: "roc-stable" }, { directory: "/nix/store/abc-git/bin", origin: "nix" }],
	variables: [{ name: "XDG_CACHE_HOME", value: "/work/cache", origin: "roc packages" }, { name: "GREETING", value: "it's here", origin: "nix" }],
}

expect Activation.shell(sample) == "export PATH='/store/bin:/nix/store/abc-git/bin':\"$PATH\"\nexport XDG_CACHE_HOME='/work/cache'\nexport GREETING='it'\\''s here'\n"
expect Activation.shell(Activation.empty) == ""
expect Activation.search_path(sample, "/usr/bin", ":") == "/store/bin:/nix/store/abc-git/bin:/usr/bin" and Activation.search_path(Activation.empty, "/usr/bin", ":") == "/usr/bin"
expect Activation.github(sample) == { path: "/store/bin\n/nix/store/abc-git/bin\n", env: "XDG_CACHE_HOME=/work/cache\nGREETING=it's here\n" }
expect Activation.github(Activation.{ path: [], variables: [{ name: "MULTI", value: "a\nb", origin: "x" }] }).env == "MULTI<<BLUEPRINT_EOF\na\nb\nBLUEPRINT_EOF\n"

# Merging keeps the first search path ahead, drops a repeated directory, and
# lets a later export of the same variable win.
expect {
	later = Activation.{ path: [{ directory: "/nix/store/abc-git/bin", origin: "nix" }, { directory: "/other/bin", origin: "nix" }], variables: [{ name: "GREETING", value: "later", origin: "nix" }] }
	merged = Activation.merge(sample, later)
	Activation.directories(merged) == ["/store/bin", "/nix/store/abc-git/bin", "/other/bin"]
		and merged.variables == [{ name: "XDG_CACHE_HOME", value: "/work/cache", origin: "roc packages" }, { name: "GREETING", value: "later", origin: "nix" }]
}

expect Activation.to_json(sample).map_ok(|text| text.contains("\"format\":1") and text.contains("\"directory\":\"/store/bin\"") and text.contains("\"origin\":\"nix\"")) == Ok(True)
expect Activation.valid_name("XDG_CACHE_HOME") and Activation.valid_name("_x1") and !Activation.valid_name("1x") and !Activation.valid_name("A-B") and !Activation.valid_name("")
