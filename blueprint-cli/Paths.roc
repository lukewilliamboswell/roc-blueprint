## Absolute paths as the CLI holds them: text with `/` between names on every
## host. A POSIX path starts at `/`. A Windows path starts at a drive, `D:/`,
## which Windows accepts wherever it accepts `D:\`. Everything here is lexical;
## the CLI observes the filesystem itself.
Paths := [].{

	## Where an absolute path starts: `/`, or a drive such as `D:/`.
	root_of : Str -> Try(Str, [Relative])
	root_of = |value|
		match value.to_utf8() {
			['/', ..] => Ok("/")
			[letter, ':', '/', ..] if drive_letter(letter) => Ok(Str.from_utf8_lossy([letter, ':', '/']))
			_ => Err(Relative)
		}

	absolute : Str -> Bool
	absolute = |value| root_of(value).is_ok()

	## A path Windows reported, in the form held here. `canonicalize` there
	## answers with the verbatim prefix `\\?\`, under which `/` is not a
	## separator, so the prefix goes and each `\` becomes `/`. Only a path that
	## starts at a drive is rewritten: on POSIX `\` is an ordinary byte of a
	## name, and a share (`\\server\share`) has no form here and stays relative.
	portable : Str -> Str
	portable = |value| {
		plain = if value.starts_with(verbatim) value.drop_prefix(verbatim) else value
		match plain.to_utf8() {
			[letter, ':', separator, ..] if drive_letter(letter) and (separator == '\\' or separator == '/') => plain.replace_each("\\", "/")
			_ => value
		}
	}

	## A caller's location against a root. The root says which host this is: a
	## drive is a root only beside a root that starts at one, so a POSIX
	## directory named `D:` stays a name.
	resolve : Str, Str -> Str
	resolve = |root, value|
		if root.starts_with("/") {
			if value.starts_with("/") value else "${root}/${value}"
		} else {
			given = portable(value)
			if absolute(given) and !given.starts_with("/") given else "${root.drop_suffix("/")}/${given.replace_each("\\", "/")}"
		}

	## Lexical normalization is separate from the runtime no-symlink check.
	normalize : Str -> Str
	normalize = |value| {
		root = root_of(value) ?? "/"
		rest = if value.starts_with(root) value.drop_prefix(root) else value
		parts = rest.split_on("/").fold(
			[],
			|acc, part|
				match part {
					"" | "." => acc
					".." => acc.drop_last(1)
					_ => acc.append(part)
				},
		)
		"${root}${Str.join_with(parts, "/")}"
	}

	## The directory holding a normalized absolute path; a root holds itself.
	parent : Str -> Str
	parent = |value| {
		root = root_of(value) ?? "/"
		result = Str.join_with(value.split_on("/").drop_last(1), "/")
		if result.to_utf8().len() < root.to_utf8().len() root else result
	}
}

verbatim : Str
verbatim = "\\\\?\\"

drive_letter : U8 -> Bool
drive_letter = |byte| (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z')

expect Paths.root_of("/project") == Ok("/") and Paths.root_of("D:/a/project") == Ok("D:/") and Paths.root_of("d:/") == Ok("d:/")
expect ["", "project", "./project", "D:", "D:project", "D:\\project", "1:/project"].all(|value| !Paths.absolute(value))

expect Paths.portable("\\\\?\\D:\\a\\project") == "D:/a/project"
expect Paths.portable("D:\\a\\project") == "D:/a/project" and Paths.portable("D:/a\\project") == "D:/a/project"

# A POSIX path keeps every byte, and a share is not given a form it lacks.
expect ["/project/a\\b", "a\\b", "\\\\server\\share", "\\\\?\\UNC\\server\\share", "D:name"].all(|value| Paths.portable(value) == value)

## Relative caller locations use the project root, not generated nesting.
expect Paths.resolve("/project", "cache/nix") == "/project/cache/nix"

## An out-of-tree caller location remains independent of the project root.
expect Paths.resolve("/project", "/tmp/cache") == "/tmp/cache"

# A drive is only a name beside a POSIX root.
expect Paths.resolve("/project", "D:/cache") == "/project/D:/cache" and Paths.resolve("/project", "D:\\cache") == "/project/D:\\cache"

expect Paths.resolve("D:/a/project", ".blueprint") == "D:/a/project/.blueprint"
expect Paths.resolve("D:/a/project", "work\\nix") == "D:/a/project/work/nix"
expect Paths.resolve("D:/a/project", "E:\\cache") == "E:/cache" and Paths.resolve("D:/a/project", "\\\\?\\E:\\cache") == "E:/cache"
expect Paths.resolve("D:/", "work") == "D:/work"

## Equivalent lexical locations normalize before filesystem safety checks.
expect Paths.normalize("/project/a/.././.blueprint/") == "/project/.blueprint"
expect Paths.normalize("/") == "/" and Paths.normalize("/..") == "/"
expect Paths.normalize("D:/a/project/x/.././.blueprint/") == "D:/a/project/.blueprint"
expect Paths.normalize("D:/") == "D:/" and Paths.normalize("D:/..") == "D:/"

expect Paths.parent("/project/.blueprint") == "/project" and Paths.parent("/project") == "/" and Paths.parent("/") == "/"
expect Paths.parent("D:/a/project") == "D:/a" and Paths.parent("D:/a") == "D:/" and Paths.parent("D:/") == "D:/"
