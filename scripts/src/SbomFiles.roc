import cli.File
import cli.Path

## The only filesystem boundary in SBOM reporting: regular inputs, bounded
## metadata reads, streaming final-byte SHA256 and exclusive new sidecars.
SbomFiles := [].{
	read! : Str => Try(Str, _)
	read! = |name| {
		path = Path.utf8(name)
		if !Path.is_file!(path)? {
			return Err(NotRegularFile)
		}
		reader = File.open_reader!(path)?
		var $bytes = []
		var $done = False
		while !$done {
			match reader.read_up_to!(65536) {
				Ok(chunk) => {
					$bytes = $bytes.concat(chunk)
					if $bytes.len() > 1024 * 1024 {
						return Err(InputTooLarge)
					}
				}
				Err(EndOfInput) => {
					$done = True
				}
				Err(error) => return Err(error)
			}
		}
		Str.from_utf8($bytes).map_err(|_| InvalidUtf8)
	}

	digest! : Str => Try(Str, _)
	digest! = |name| {
		path = Path.utf8(name)
		if !Path.is_file!(path)? {
			return Err(NotRegularFile)
		}
		reader = File.open_reader!(path)?
		var $hasher = Crypto.SHA256.Hasher.empty()
		var $done = False
		while !$done {
			match reader.read_up_to!(65536) {
				Ok(bytes) => {
					$hasher = $hasher.write(bytes)
				}
				Err(EndOfInput) => {
					$done = True
				}
				Err(error) => return Err(error)
			}
		}
		Ok($hasher.finish().to_hex())
	}

	write_new! : Str, Str => Try({}, _)
	write_new! = |output, text| File.with_writer!(Path.utf8(output), RequireNew, |writer| writer.write_utf8!(text))
}
