## Pure public build report: native identities/details belong to their provider.
import core.Provider
import core.Lock
import core.Value
import core.BuildModel
import ReportJson

BuildReport := [].{
	render_evidence : Str, Str, Str, Provider.BuildResult, List(Lock.Source), BuildModel.Snapshot -> Try(Str, Str)
	render_evidence = |name, system, provider, built, sources, snapshot| {
		common = fields(name, system, provider, built, sources)?
		Ok(
			ReportJson.object(
				common.append(("snapshot_digest", Json.to_str(BuildModel.digest(snapshot)))),
			).concat("\n"),
		)
	}

	render : Str, Str, Str, Provider.BuildResult, List(Lock.Source) -> Try(Str, Str)
	render = |name, system, provider, built, sources| Ok(ReportJson.object(fields(name, system, provider, built, sources)?).concat("\n"))

	fields : Str, Str, Str, Provider.BuildResult, List(Lock.Source) -> Try(List((Str, Str)), Str)
	fields = |name, system, provider, built, sources| {
		if provider.trim().is_empty() {
			return Err("build report has no provider identity")
		}
		if built.build_identity.trim().is_empty() {
			return Err("build report has no build identity")
		}
		metadata = ReportJson.object([(provider, ReportJson.value(Value.Attrs(built.metadata))?)])
		Ok([
			("schema_version", "2"),
			("name", Json.to_str(name)),
			("system", Json.to_str(system)),
			("provider", Json.to_str(provider)),
			("build_identity", Json.to_str(built.build_identity)),
			("outputs", Json.to_str(built.outputs)),
			("sources", Json.to_str(sources)),
			("metadata", metadata),
		])
	}
}
