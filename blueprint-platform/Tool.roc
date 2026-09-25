import core.Spec
import core.Project

## A provider-native tool name, optionally qualified as "source#name".
## Generic syntax is checked here; explicit source grammar is checked during
## whole-project validation. Auto sources are interpreted by the chosen provider.
Tool :: { source : Str, name : Str }.{
	from_quote : Str -> Try(Tool, [BadQuotedBytes(Str)])
	from_quote = |raw|
		match Project.tool(raw) {
			Ok(tool) => Ok(Tool.{ source: tool.source, name: tool.name })
			Err(error) => Err(BadQuotedBytes(error))
		}

	to_spec : Tool -> Spec.Tool
	to_spec = |tool| { source: tool.source, name: tool.name }

	to_str : Tool -> Str
	to_str = |tool|
		if tool.source == "default" {
			tool.name
		} else {
			"${tool.source}#${tool.name}"
		}
}
