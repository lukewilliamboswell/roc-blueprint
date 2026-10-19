import Config
import NightlyTag
import System
import Url
import UrlTemplate

## Recipes for programs many projects fetch. A recipe is what `Fetch` takes: a
## function from a System, such as "x86_64-linux", to where the program is
## downloaded from there. It only answers; nothing is fetched until
## `blueprint` runs, and `Blueprint.lock` holds the digest of each download.
##
## ```roc
## Programs([
## 	Fetch("roc-stable", Recipes.roc_nightly("nightly-2026-10-04-130536d")),
## 	Fetch("tool", Recipes.file("https://example.org/releases/1.0/tool-{system}")),
## ]),
## ```
##
## A project writes its own as a function, best with its type, so that a
## mistake in it is reported where it is:
##
## ```roc
## tool : System -> Config.Download
## tool = |system|
## 	match system {
## 		"x86_64-linux" => File("https://example.org/releases/1.0/tool-linux")
## 		"aarch64-darwin" => File("https://example.org/releases/1.0/tool-macos")
## 		_ => Unavailable
## 	}
## ```
Recipes :: [].{

	## A program that is one file at a URL which names the System: "{system}",
	## "{arch}" and "{os}" in the template stand for the System asked about
	## and its two parts. The program exists for every System; a recipe of
	## the project's own says otherwise with `Unavailable`.
	file : UrlTemplate -> (System -> Config.Download)
	file = |template|
		|system| File(Url.assembled(template.for_system(system)))

	## The Roc compiler of one release of
	## [roc-lang/nightlies](https://github.com/roc-lang/nightlies/releases),
	## named by its tag, as in `nightly-2026-10-04-130536d`. The archive is
	## kept whole: on macOS `roc` links with the `darwin` directory beside it.
	## A System the nightlies are not built for is `Unavailable`.
	roc_nightly : NightlyTag -> (System -> Config.Download)
	roc_nightly = |nightly|
		|system| {
			tag = nightly.to_str()
			{ build, extension, program } = match system {
				"x86_64-linux" => { build: "linux_x86_64", extension: ".tar.gz", program: "roc" }
				"aarch64-linux" => { build: "linux_arm64", extension: ".tar.gz", program: "roc" }
				"aarch64-darwin" => { build: "macos_apple_silicon", extension: ".tar.gz", program: "roc" }
				"x86_64-darwin" => { build: "macos_x86_64", extension: ".tar.gz", program: "roc" }
				"x86_64-windows" => { build: "windows_x86_64", extension: ".zip", program: "roc.exe" }
				_ => return Unavailable
			}
			top = "roc_nightly-${build}-${tag.drop_prefix("nightly-")}"
			Archive(
				"https://github.com/roc-lang/nightlies/releases/download/${tag}/${top}${extension}",
				if (extension == ".zip") Zip else TarGz,
				"${top}/${program}",
			)
		}
}

october : System -> Config.Download
october = Recipes.roc_nightly("nightly-2026-10-04-130536d")

## A download as text, for comparing: the checked types have no literal of
## an assembled URL.
shown : Config.Download -> Str
shown = |download|
	match download {
		File(url) => "File ${url.to_str()}"
		Archive(url, TarGz, member) => "TarGz ${url.to_str()} ${member.to_str()}"
		Archive(url, TarXz, member) => "TarXz ${url.to_str()} ${member.to_str()}"
		Archive(url, Zip, member) => "Zip ${url.to_str()} ${member.to_str()}"
		Mirrored(_, _) => "Mirrored"
		Unavailable => "Unavailable"
	}

# Each System's asset and the compiler inside it, as the release names them.
expect shown(october("x86_64-linux")) == "TarGz https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-04-130536d/roc_nightly-linux_x86_64-2026-10-04-130536d.tar.gz roc_nightly-linux_x86_64-2026-10-04-130536d/roc"
expect shown(october("aarch64-linux")) == "TarGz https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-04-130536d/roc_nightly-linux_arm64-2026-10-04-130536d.tar.gz roc_nightly-linux_arm64-2026-10-04-130536d/roc"
expect shown(october("aarch64-darwin")) == "TarGz https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-04-130536d/roc_nightly-macos_apple_silicon-2026-10-04-130536d.tar.gz roc_nightly-macos_apple_silicon-2026-10-04-130536d/roc"
expect shown(october("x86_64-darwin")) == "TarGz https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-04-130536d/roc_nightly-macos_x86_64-2026-10-04-130536d.tar.gz roc_nightly-macos_x86_64-2026-10-04-130536d/roc"
expect shown(october("x86_64-windows")) == "Zip https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-04-130536d/roc_nightly-windows_x86_64-2026-10-04-130536d.zip roc_nightly-windows_x86_64-2026-10-04-130536d/roc.exe"

# No nightly is built for any other System, and nothing is guessed for one.
expect ["aarch64-windows", "riscv64-linux", "x86_64-freebsd", "i686-linux"].all(|system| shown(october(system)) == "Unavailable")

# What it answers is a download URL and a path, though both are assembled.
expect
	["x86_64-linux", "aarch64-linux", "aarch64-darwin", "x86_64-darwin", "x86_64-windows"].all(
		|system|
			match october(system) {
				Archive(url, _, member) => Url.from_quote(url.to_str()) == Ok(url) and member.to_str().ends_with("/roc") or member.to_str().ends_with("/roc.exe")
				_ => False
			},
	)

# A file recipe writes the System, or a part of it, into its template.
expect shown(Recipes.file("https://example.org/releases/1.0/tool-{system}")("aarch64-darwin")) == "File https://example.org/releases/1.0/tool-aarch64-darwin"
expect shown(Recipes.file("https://example.org/{os}/tool-{arch}")("x86_64-windows")) == "File https://example.org/windows/tool-x86_64"
expect shown(Recipes.file("https://example.org/tool")("riscv64-freebsd")) == "File https://example.org/tool"
