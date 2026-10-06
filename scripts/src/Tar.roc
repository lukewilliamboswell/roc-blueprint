## A strict reader for ustar archives held in memory. It accepts only regular
## files with safe, unique, relative names, so no archiver ever creates a path,
## link or device on this script's behalf.
Tar := [].{
	Entry : { name : Str, data : List(U8) }
	Limits : { members : U64, bytes : U64 }

	## A relative path of portable characters with no empty, `.` or `..` part.
	safe_name : Str -> Bool
	safe_name = |name| {
		parts = Str.split_on(name, "/")
		!name.is_empty() and !name.starts_with("-")
			and !parts.any(|part| part.is_empty() or part == "." or part == "..")
				and name.to_utf8().all(|b| (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or b == '+' or b == '-' or b == '.' or b == '/' or b == '_')
	}

	## Every member of the archive, in order. Anything other than a regular
	## file, an unsafe or repeated name, a bad header checksum, more members or
	## bytes than `limits` allows, or a truncated archive is an error.
	entries : List(U8), Limits -> Try(List(Entry), [TarInvalid(Str)])
	entries = |bytes, limits| {
		var $offset = 0
		var $total = 0
		var $entries = []
		while $offset < bytes.len() {
			block = bytes.sublist({ start: $offset, len: 512 })
			if block.len() != 512 {
				return Err(TarInvalid("truncated header at byte ${$offset.to_str()}"))
			}
			if block.all(|b| b == 0) {
				if !bytes.drop_first($offset).all(|b| b == 0) {
					return Err(TarInvalid("data follows the end-of-archive marker"))
				}
				return Ok($entries)
			}
			header = parse_header(block)?
			if $entries.len() >= limits.members {
				return Err(TarInvalid("more than ${limits.members.to_str()} members"))
			}
			if !Tar.safe_name(header.name) {
				return Err(TarInvalid("unsafe member name: ${header.name}"))
			}
			if header.typeflag != '0' and header.typeflag != 0 {
				return Err(TarInvalid("member is not a regular file: ${header.name}"))
			}
			if $entries.any(|entry| entry.name == header.name) {
				return Err(TarInvalid("duplicate member: ${header.name}"))
			}
			if header.size > limits.bytes - $total {
				return Err(TarInvalid("members expand to more than ${limits.bytes.to_str()} bytes"))
			}
			start = $offset + 512
			if start + header.size > bytes.len() {
				return Err(TarInvalid("truncated member: ${header.name}"))
			}
			$entries = $entries.append({ name: header.name, data: bytes.sublist({ start, len: header.size }) })
			$total = $total + header.size
			$offset = start + (header.size + 511) // 512 * 512
		}
		Err(TarInvalid("no end-of-archive marker"))
	}
}

parse_header : List(U8) -> Try({ name : Str, size : U64, typeflag : U8 }, [TarInvalid(Str)])
parse_header = |block| {
	stored = octal(block.sublist({ start: 148, len: 8 }))?
	sum = |bytes| bytes.fold(0, |total, b| total + b.to_u64())
	if sum(block) - sum(block.sublist({ start: 148, len: 8 })) + 8 * 32 != stored {
		return Err(TarInvalid("bad header checksum"))
	}
	base = text(block.sublist({ start: 0, len: 100 }))?
	prefix = if block.sublist({ start: 257, len: 5 }) == "ustar".to_utf8() text(block.sublist({ start: 345, len: 155 }))? else ""
	Ok({
		name: if prefix.is_empty() base else "${prefix}/${base}",
		size: octal(block.sublist({ start: 124, len: 12 }))?,
		typeflag: block.get(156) ?? 255,
	})
}

## A NUL-terminated header field as UTF-8 text.
text : List(U8) -> Try(Str, [TarInvalid(Str)])
text = |field| {
	bytes = match field.split_on(0) {
		[first, ..] => first
		[] => []
	}
	Str.from_utf8(bytes).map_err(|_| TarInvalid("member name is not UTF-8"))
}

## An octal header field, terminated by NUL or space.
octal : List(U8) -> Try(U64, [TarInvalid(Str)])
octal = |field| {
	digits = field.keep_if(|b| b != 0 and b != ' ')
	if digits.is_empty() or !digits.all(|b| b >= '0' and b <= '7') {
		return Err(TarInvalid("bad numeric header field"))
	}
	Ok(digits.fold(0, |total, b| total * 8 + (b - '0').to_u64()))
}

## Test archives: one 512-byte header per member, its padded data, then the
## two zero blocks that end an archive.
archive : List({ name : Str, typeflag : U8, data : List(U8) }) -> List(U8)
archive = |members|
	members.fold([], |bytes, member| bytes.concat(member_bytes(member))).concat(List.repeat(0, 1024))

member_bytes = |member| {
	size = member.data.len()
	padding = (512 - size % 512) % 512
	unsummed = pad(member.name.to_utf8(), 100)
		.concat("0000644".to_utf8().append(0))
		.concat("0000000".to_utf8().append(0))
		.concat("0000000".to_utf8().append(0))
		.concat(octal_digits(size, 11).append(0))
		.concat(octal_digits(0, 11).append(0))
		.concat(List.repeat(' ', 8))
		.append(member.typeflag)
		.concat(List.repeat(0, 100))
		.concat("ustar".to_utf8().append(0))
		.concat("00".to_utf8())
	checksum = unsummed.fold(0, |total, b| total + b.to_u64())
	header = unsummed.sublist({ start: 0, len: 148 })
		.concat(octal_digits(checksum, 6).append(0).append(' '))
		.concat(unsummed.drop_first(156))
	pad(header, 512).concat(member.data).concat(List.repeat(0, padding))
}

pad = |bytes, length| bytes.concat(List.repeat(0, length - bytes.len()))

octal_digits : U64, U64 -> List(U8)
octal_digits = |value, width| {
	var $digits = []
	var $rest = value
	while $digits.len() < width {
		$digits = [(($rest % 8).to_u8_wrap()) + '0'].concat($digits)
		$rest = $rest // 8
	}
	$digits
}

limits = { members: 8, bytes: 4096 }

file = |name, content| { name, typeflag: '0', data: content.to_utf8() }

rejects = |members, bounds| match Tar.entries(archive(members), bounds) {
	Ok(_) => Bool.False
	Err(TarInvalid(_)) => Bool.True
}

expect Tar.safe_name("targets/x64musl/libc.a")
expect !Tar.safe_name("")
expect !Tar.safe_name("/absolute")
expect !Tar.safe_name("../outside")
expect !Tar.safe_name("a/../b")
expect !Tar.safe_name("a//b")
expect !Tar.safe_name("dir/")
expect !Tar.safe_name("-option")
expect !Tar.safe_name("a b")
expect !Tar.safe_name("a\\b")

# Members come back in order with their exact bytes.
expect Tar.entries(archive([file("a.txt", "one"), file("dir/b.txt", "")]), limits) == Ok([{ name: "a.txt", data: "one".to_utf8() }, { name: "dir/b.txt", data: [] }])
# Symbolic links, hard links and directories are not regular files.
expect rejects([{ name: "link", typeflag: '2', data: [] }], limits)
expect rejects([{ name: "hard", typeflag: '1', data: [] }], limits)
expect rejects([{ name: "dir", typeflag: '5', data: [] }], limits)
# Extended headers could rename a later member, so they are refused too.
expect rejects([{ name: "pax", typeflag: 'x', data: [] }], limits)
expect rejects([file("../escape", "x")], limits)
expect rejects([file("/etc/passwd", "x")], limits)
expect rejects([file("a", "x"), file("a", "y")], limits)
expect rejects([file("a", "x"), file("b", "y")], { members: 1, bytes: 4096 })
expect rejects([file("a", "four")], { members: 8, bytes: 3 })
# A flipped header byte no longer matches its checksum.
expect {
	bytes = archive([file("a", "x")])
	damaged = ['b'].concat(bytes.drop_first(1))
	Tar.entries(damaged, limits) == Err(TarInvalid("bad header checksum"))
}
# The data and the end-of-archive marker must both be present.
expect {
	bytes = archive([file("a", "x")])
	Tar.entries(bytes.take_first(512), limits) == Err(TarInvalid("truncated member: a"))
}
expect {
	bytes = archive([file("a", "x")])
	Tar.entries(bytes.take_first(1024), limits) == Err(TarInvalid("no end-of-archive marker"))
}
expect {
	bytes = archive([file("a", "x")])
	Tar.entries(bytes.concat([1]), limits) == Err(TarInvalid("data follows the end-of-archive marker"))
}
