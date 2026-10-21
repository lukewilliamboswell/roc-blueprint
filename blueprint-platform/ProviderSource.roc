# A checked, versioned source declaration for adapter-owned native references.
# Adapters supply a pure validator; callers cannot construct unchecked fields.
ProviderSource := { provider : Str, version : U64, reference : Str }.{
	is_eq : _
	checked : Str, U64, Str, (Str -> Try({}, Str)) -> Try(ProviderSource, Str)
	checked = |provider, version, reference, validate| {
		if provider.is_empty() or !provider.to_utf8().all(|byte| (byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or byte == '-') or version == 0 {
			return Err("invalid provider name or declaration version")
		}
		_ = validate(reference)?
		if reference.is_empty() or reference.to_utf8().any(|byte| byte <= 32 or byte == 127) {
			return Err("invalid source reference")
		}
		Ok(ProviderSource.{ provider, version, reference })
	}

	provider : ProviderSource -> Str
	provider = |source| source.provider
	version : ProviderSource -> U64
	version = |source| source.version
	reference : ProviderSource -> Str
	reference = |source| source.reference
}

expect ProviderSource.checked("fixture", 1, "native:content", |_reference| Ok({})).map_ok(|source| (source.provider(), source.version(), source.reference())) == Ok(("fixture", 1, "native:content"))
expect ProviderSource.checked("fixture", 1, "native:content", |_reference| Err("unsupported source")) == Err("unsupported source")
