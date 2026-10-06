## The pins of a Nix `flake.lock`, read from the text Nix writes: two-space
## indentation, one key per line.
FlakeLock := [].{
	Pin : { owner : Str, repo : Str, rev : Str, nar_hash : Str }

	## The locked GitHub revision of the input node `name`.
	locked : Str, Str -> Try(Pin, [NoPin(Str)])
	locked = |text, name| {
		missing = NoPin(name)
		node = between(text, "\n    \"${name}\": {\n", "\n    }").map_err(|_| missing)?
		pin = between(node, "\"locked\": {\n", "\n      }").map_err(|_| missing)?
		if field(pin, "type") != Ok("github") {
			return Err(missing)
		}
		Ok({
			owner: field(pin, "owner").map_err(|_| missing)?,
			repo: field(pin, "repo").map_err(|_| missing)?,
			rev: field(pin, "rev").map_err(|_| missing)?,
			nar_hash: field(pin, "narHash").map_err(|_| missing)?,
		})
	}

	## The flake reference of exactly that revision.
	ref : Pin -> Str
	ref = |pin| "github:${pin.owner}/${pin.repo}/${pin.rev}"

	## The reference with its content hash, as Nix writes it in a URL: the
	## base64 characters `+`, `/` and `=` percent-encoded.
	ref_with_hash : Pin -> Str
	ref_with_hash = |pin| {
		encoded = pin.nar_hash.replace_each("+", "%2B").replace_each("/", "%2F").replace_each("=", "%3D")
		"${ref(pin)}?narHash=${encoded}"
	}
}

## The text after the first `start` up to the next `end`.
between : Str, Str, Str -> Try(Str, [NotFound])
between = |text, start, end|
	match text.split_on(start) {
		[_, after, ..] =>
			match after.split_on(end) {
				[inside, _, ..] => Ok(inside)
				_ => Err(NotFound)
			}
		_ => Err(NotFound)
	}

## The string value of `"name": "value"` on a line of its own.
field : Str, Str -> Try(Str, [NotFound])
field = |text, name| {
	prefix = "\"${name}\": \""
	match text.split_on("\n").map(|line| line.trim()).find_first(|line| line.starts_with(prefix)) {
		Ok(line) => Ok(line.drop_prefix(prefix).drop_suffix(",").drop_suffix("\""))
		Err(_) => Err(NotFound)
	}
}

sample =
	\\{
	\\  "nodes": {
	\\    "nixpkgs": {
	\\      "locked": {
	\\        "lastModified": 1790046670,
	\\        "narHash": "sha256-MYiI+CzL0tuW/RPjGs=",
	\\        "owner": "NixOS",
	\\        "repo": "nixpkgs",
	\\        "rev": "6774f7bc",
	\\        "type": "github"
	\\      },
	\\      "original": {
	\\        "owner": "NixOS",
	\\        "ref": "nixos-unstable",
	\\        "repo": "nixpkgs",
	\\        "type": "github"
	\\      }
	\\    },
	\\    "roc-overlay": {
	\\      "inputs": {
	\\        "nixpkgs": [
	\\          "nixpkgs"
	\\        ]
	\\      },
	\\      "locked": {
	\\        "narHash": "sha256-R4Zj=",
	\\        "owner": "roc-lang",
	\\        "repo": "roc-overlay",
	\\        "rev": "fb02fef7",
	\\        "type": "github"
	\\      },
	\\      "original": {
	\\        "owner": "roc-lang",
	\\        "repo": "roc-overlay",
	\\        "type": "github"
	\\      }
	\\    },
	\\    "local": {
	\\      "locked": {
	\\        "narHash": "sha256-AAAA",
	\\        "path": "/somewhere",
	\\        "type": "path"
	\\      }
	\\    },
	\\    "root": {
	\\      "inputs": {
	\\        "nixpkgs": "nixpkgs",
	\\        "roc-overlay": "roc-overlay"
	\\      }
	\\    }
	\\  },
	\\  "root": "root",
	\\  "version": 7
	\\}

expect FlakeLock.locked(sample, "nixpkgs") == Ok({ owner: "NixOS", repo: "nixpkgs", rev: "6774f7bc", nar_hash: "sha256-MYiI+CzL0tuW/RPjGs=" })
expect FlakeLock.locked(sample, "roc-overlay") == Ok({ owner: "roc-lang", repo: "roc-overlay", rev: "fb02fef7", nar_hash: "sha256-R4Zj=" })

# A node without a GitHub pin, and a name that is only an input alias, have none.
expect FlakeLock.locked(sample, "root") == Err(NoPin("root"))
expect FlakeLock.locked(sample, "local") == Err(NoPin("local"))
expect FlakeLock.locked(sample, "missing") == Err(NoPin("missing"))
expect FlakeLock.locked("{}", "nixpkgs") == Err(NoPin("nixpkgs"))

expect FlakeLock.locked(sample, "nixpkgs").map_ok(FlakeLock.ref) == Ok("github:NixOS/nixpkgs/6774f7bc")
expect FlakeLock.locked(sample, "nixpkgs").map_ok(FlakeLock.ref_with_hash) == Ok("github:NixOS/nixpkgs/6774f7bc?narHash=sha256-MYiI%2BCzL0tuW%2FRPjGs%3D")
