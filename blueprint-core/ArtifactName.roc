## A portable final artifact or sidecar filename, never a path. These are
## Win32's documented filename restrictions, applied on every host so a
## published binding does not acquire another meaning on Windows.
## https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-file
ArtifactName := [].{
	valid : Str -> Bool
	valid = |name| {
		if name.is_empty() or name == "." or name == ".." or name.ends_with(".") or name.ends_with(" ") {
			return False
		}
		if name.to_utf8().any(|byte| byte < 32 or byte == 127 or "<>:\"/\\|?*".to_utf8().contains(byte)) {
			return False
		}
		# Devices remain reserved with an extension. Superscript digits are
		# Win32 COM/LPT aliases too. Ordinary Unicode/interior spaces remain.
		var $stem = key(name.split_on(".").first() ?? "")
		while $stem.ends_with(" ") {
			$stem = $stem.drop_suffix(" ")
		}
		!["con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9", "com¹", "com²", "com³", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9", "lpt¹", "lpt²", "lpt³"].contains($stem)
	}

	## Detect ASCII case aliases without claiming filesystem canonicalization
	## of Unicode normalization, 8.3 names, links or mount-specific aliases.
	key : Str -> Str
	key = |name| Str.from_utf8(name.to_utf8().map(|byte| if (byte >= 'A' and byte <= 'Z') byte + 32 else byte)) ?? name
}
