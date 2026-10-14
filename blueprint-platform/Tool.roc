import core.Spec
import core.Project

## A tool a package source supplies, written `<source>#<name>`: the source is
## one the configuration declares with `Packages`, and the name is that
## source's own for the package. The source is always written: no source is
## implied, so a name alone is refused here, where it is written. Whether the
## source is declared, and its grammar for the name, are checked during
## whole-project validation.
Tool :: { source : Str, name : Str }.{
	from_quote : Str -> Try(Tool, [BadQuotedBytes(Str)])
	from_quote = |raw|
		if raw.contains("#") {
			match Project.tool(raw) {
				Ok(tool) => Ok(Tool.{ source: tool.source, name: tool.name })
				Err(error) => Err(BadQuotedBytes(error))
			}
		} else {
			Err(BadQuotedBytes(unqualified(raw)))
		}

	## What to write instead of a tool with no source: both ways out, since
	## only the author knows whether the tool is to be installed or is the
	## machine's own.
	unqualified : Str -> Str
	unqualified = |raw|
		"\"${raw}\" names no package source. Write \"<source>#${raw}\" for a declared source, as in Packages(\"nix\", From(NixPackages(\"github:NixOS/nixpkgs/nixos-unstable\"))) and \"nix#${raw}\"; or, if ${raw} is already on the machine, list it in Expect."

	to_spec : Tool -> Spec.Tool
	to_spec = |tool| { source: tool.source, name: tool.name }

	to_str : Tool -> Str
	to_str = |tool| "${tool.source}#${tool.name}"
}

# A tool names its source, and is written back as it was.
expect Tool.from_quote("nix#git").map_ok(|tool| (tool.to_spec(), tool.to_str())) == Ok(({ source: "nix", name: "git" }, "nix#git"))
expect Tool.from_quote("stable#python3Packages.requests").map_ok(|tool| tool.to_spec()) == Ok({ source: "stable", name: "python3Packages.requests" })

# A name alone is refused with both fixes, whatever sources are declared: a
# source called `default` is named like any other.
expect Tool.from_quote("git").map_ok(|tool| tool.to_str()) == Err(BadQuotedBytes("\"git\" names no package source. Write \"<source>#git\" for a declared source, as in Packages(\"nix\", From(NixPackages(\"github:NixOS/nixpkgs/nixos-unstable\"))) and \"nix#git\"; or, if git is already on the machine, list it in Expect."))
expect Tool.from_quote("default#git").map_ok(|tool| tool.to_str()) == Ok("default#git")

# Anything else that is not `<source>#<name>` is no tool reference.
expect ["one#two#three", "#git", "nix#", "bad name#git", "nix#git\n"].all(|raw| Tool.from_quote(raw).map_ok(|tool| tool.to_str()) == Err(BadQuotedBytes("invalid tool reference: ${raw}")))
