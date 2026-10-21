## Pure public build report: native identities/details belong to their provider.
import core.Provider
import core.Lock
import core.Value
import ReportJson

BuildReport := [].{
	render : Str, Str, Str, Provider.BuildResult, List(Lock.Source) -> Try(Str, Str)
	render = |name, system, provider, built, sources| {
		if provider.trim().is_empty() {
			return Err("build report has no provider identity")
		}
		if built.recipe_identity.trim().is_empty() {
			return Err("build report has no recipe identity")
		}
		metadata = ReportJson.object([(provider, ReportJson.value(Value.Attrs(built.metadata))?)])
		Ok(
			ReportJson.object([
				("schema_version", "1"),
				("name", Json.to_str(name)),
				("system", Json.to_str(system)),
				("provider", Json.to_str(provider)),
				("recipe_identity", Json.to_str(built.recipe_identity)),
				("outputs", Json.to_str(built.outputs)),
				("sources", Json.to_str(sources)),
				("metadata", metadata),
			]).concat("\n"),
		)
	}
}
