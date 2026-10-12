## Turning a release's notes into the body of its GitHub release.
##
## The notes are written by hand in `docs/releases/<version>.adoc`, as part of
## the manual. They cannot name the release's bundle URLs, because each holds
## the hash of a bundle that does not exist until the release builds it. They
## say `{platform-url}` and `{core-url}` instead, and the release fills them in.
Notes := [].{

	## What stands for a bundle's URL in the notes, and the URL.
	Url : { placeholder : Str, url : Str }

	## Render the AsciiDoc `source` as Markdown, with each placeholder replaced
	## by its URL. The notes must open with `title` and use every placeholder,
	## and must leave no other `{...-url}` unresolved.
	##
	## Only what release notes use is converted: headings, source blocks and
	## links. Paragraphs, lists and `code` read the same in both.
	render : Str, { title : Str, urls : List(Url) } -> Try(Str, [WrongTitle(Str), UnusedPlaceholder(Str), UnresolvedPlaceholder(Str), UnclosedBlock])
	render = |source, { title, urls }|
		match Str.split_on(source, "\n") {
			[first, .. as body] if first == title => {
				match urls.find_first(|bundle| !source.contains(bundle.placeholder)) {
					Ok(unused) => return Err(UnusedPlaceholder(unused.placeholder))
					Err(_) => {}
				}
				filled = body.map(|line| urls.fold(line, |text, bundle| Str.replace_each(text, bundle.placeholder, bundle.url)))
				lines = convert(filled, Prose, [])?
				match lines.keep_oks(unresolved) {
					[name, ..] => Err(UnresolvedPlaceholder(name))
					[] => Ok("${Str.join_with(lines, "\n").trim()}\n")
				}
			}
			[first, ..] => Err(WrongTitle(first))
			[] => Err(WrongTitle(""))
		}

	## The versions a chapter of release notes includes, in its order: one
	## `include::releases/<version>.adoc[...]` line each.
	included : Str -> List(Str)
	included = |chapter|
		chapter.split_on("\n").keep_if(|line| line.starts_with(include_prefix)).map(
			|line| line.drop_prefix(include_prefix).split_on(".adoc[").first() ?? "",
		)

	## The chapter must include exactly the notes files there are.
	chapter_problem : Str, List(Str) -> Str
	chapter_problem = |chapter, files| {
		listed = included(chapter)
		written = files.keep_if(|name| name.ends_with(".adoc")).map(|name| name.drop_suffix(".adoc"))
		unlisted = written.keep_if(|version| !listed.contains(version))
		absent = listed.keep_if(|version| !written.contains(version))
		if unlisted.is_empty() and absent.is_empty() {
			""
		} else {
			"docs/releases.adoc must include exactly the notes in docs/releases (not included: ${Str.join_with(unlisted, " ")}; included but absent: ${Str.join_with(absent, " ")})"
		}
	}
}

include_prefix = "include::releases/"

convert : List(Str), [Prose, Block], List(Str) -> Try(List(Str), [UnclosedBlock])
convert = |lines, state, out|
	match (state, lines) {
		(Prose, []) => Ok(out)
		(Block, []) => Err(UnclosedBlock)
		(Block, ["----", .. as rest]) => convert(rest, Prose, out.append("```"))
		(Block, [line, .. as rest]) => convert(rest, Block, out.append(line))
		(Prose, [declared, "----", .. as rest]) if declared.starts_with("[source") => convert(rest, Block, out.append("```${language(declared)}"))
		(Prose, ["----", .. as rest]) => convert(rest, Block, out.append("```"))
		(Prose, [line, .. as rest]) => convert(rest, Prose, out.append(links(heading(line))))
	}

# `[source,roc]` names its language second.
language = |declared|
	match Str.split_on(declared.drop_prefix("[").drop_suffix("]"), ",") {
		[_, name, ..] => name.trim()
		_ => ""
	}

# A release's notes are a chapter of the manual, so their sections start at `==`.
heading = |line|
	if line.starts_with("=== ") {
		"### ${line.drop_prefix("=== ")}"
	} else if line.starts_with("== ") {
		"## ${line.drop_prefix("== ")}"
	} else {
		line
	}

# AsciiDoc writes a link as `https://example.com[text]`.
links = |line|
	match Str.split_first(line, "https://") {
		Ok({ before, after }) =>
			match Str.split_first(after, "[") {
				Ok({ before: address, after: rest }) if !address.contains(" ") =>
					match Str.split_first(rest, "]") {
						Ok({ before: text, after: remainder }) => "${before}[${text}](https://${address})${links(remainder)}"
						Err(_) => line
					}
				_ => "${before}https://${links(after)}"
			}
		Err(_) => line
	}

# The name of a `{...-url}` placeholder still in `line`.
unresolved = |line|
	match Str.split_first(line, "-url}") {
		Ok({ before, .. }) =>
			match Str.split_last(before, "{") {
				Ok({ after, .. }) if !after.contains(" ") => Ok("{${after}-url}")
				_ => Err(Resolved)
			}
		Err(_) => Err(Resolved)
	}

notes = "= roc-blueprint 0.5.0\n\nOne release.\n\n== Use this release\n\n[source,roc]\n----\napp [config] { pf: platform \"{platform-url}\" }\n----\n\nThe core package is `{core-url}`.\n\n=== Thanks\n\n* See https://example.com/a[the issue] and https://example.com/b[the fix].\n* Plain https://example.com stays.\n"

release = {
	title: "= roc-blueprint 0.5.0",
	urls: [{ placeholder: "{platform-url}", url: "https://example.com/Abc.tar.zst" }, { placeholder: "{core-url}", url: "https://example.com/core-Def.tar.zst" }],
}

expect Notes.render(notes, release) == Ok("One release.\n\n## Use this release\n\n```roc\napp [config] { pf: platform \"https://example.com/Abc.tar.zst\" }\n```\n\nThe core package is `https://example.com/core-Def.tar.zst`.\n\n### Thanks\n\n* See [the issue](https://example.com/a) and [the fix](https://example.com/b).\n* Plain https://example.com stays.\n")
expect Notes.render(notes, { ..release, title: "= roc-blueprint 0.6.0" }) == Err(WrongTitle("= roc-blueprint 0.5.0"))
expect Notes.render("= roc-blueprint 0.5.0\n\n{platform-url}\n", release) == Err(UnusedPlaceholder("{core-url}"))
expect Notes.render("= roc-blueprint 0.5.0\n\n{platform-url} {core-url} and {tzdb-url}\n", release) == Err(UnresolvedPlaceholder("{tzdb-url}"))
expect Notes.render("= roc-blueprint 0.5.0\n\n{platform-url} {core-url}\n\n----\nnever closed\n", release) == Err(UnclosedBlock)
expect Notes.render("= roc-blueprint 0.5.0\n\n----\n{platform-url}\n{core-url}\n----\n", release) == Ok("```\nhttps://example.com/Abc.tar.zst\nhttps://example.com/core-Def.tar.zst\n```\n")
expect Notes.render("", release) == Err(WrongTitle(""))

chapter = "= Release notes\n\nNewest first.\n\ninclude::releases/0.6.0.adoc[leveloffset=+1]\n\ninclude::releases/0.5.0.adoc[leveloffset=+1]\n"

expect Notes.included(chapter) == ["0.6.0", "0.5.0"]
expect Notes.chapter_problem(chapter, ["0.5.0.adoc", "0.6.0.adoc"]) == ""
expect Notes.chapter_problem(chapter, ["0.5.0.adoc", "0.6.0.adoc", "0.7.0.adoc"]) == "docs/releases.adoc must include exactly the notes in docs/releases (not included: 0.7.0; included but absent: )"
expect Notes.chapter_problem(chapter, ["0.6.0.adoc"]) == "docs/releases.adoc must include exactly the notes in docs/releases (not included: ; included but absent: 0.5.0)"
