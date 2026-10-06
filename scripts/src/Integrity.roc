## Content digests for files a committed lock authorises.
Integrity := [].{

	## The lowercase hexadecimal SHA-256 of `bytes`.
	digest : List(U8) -> Str
	digest = |bytes| Crypto.SHA256.hash(bytes).to_hex()

	## Whether `value` is exactly `length` lowercase hexadecimal digits.
	is_hex : Str, U64 -> Bool
	is_hex = |value, length| {
		bytes = value.to_utf8()
		bytes.len() == length and bytes.all(|byte| (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))
	}

	## Compare bytes with a locked size and SHA-256, naming what differs.
	verify : List(U8), { sha256 : Str, size : U64 } -> Try({}, [Mismatch(Str)])
	verify = |bytes, expected| {
		if bytes.len() != expected.size {
			return Err(Mismatch("size is ${bytes.len().to_str()} bytes, expected ${expected.size.to_str()}"))
		}
		actual = Integrity.digest(bytes)
		if actual != expected.sha256 {
			return Err(Mismatch("sha256 is ${actual}, expected ${expected.sha256}"))
		}
		Ok({})
	}
}

expect Integrity.digest("abc".to_utf8()) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
expect Integrity.is_hex("0a", 2)
expect !Integrity.is_hex("0A", 2)
expect !Integrity.is_hex("0a", 3)
expect Integrity.verify("abc".to_utf8(), { sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", size: 3 }) == Ok({})
expect Integrity.verify("abd".to_utf8(), { sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", size: 3 }) != Ok({})
expect Integrity.verify("abc".to_utf8(), { sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", size: 4 }) != Ok({})
