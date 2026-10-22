import cli.Path
import SbomFiles
import cli.Stdout
import cli.Utc
import Process
import core.Manifest
import core.Sbom
import compilers.Bootstrap
import Bundle
import Integrity
import Release
import "../../sbom/basic-cli-cargo.json" as cargo_json : Str
import "../../sbom/upstream/basic-cli-Cargo.lock" as cargo_lock_fixture : Str
import "../../blueprint-cli/compiler-version" as compiler_version : Str
import "../../flake.lock" as flake_lock_json : Str
import "../../link-inputs.lock.json" as native_json : Str

## Reviewed composition of this repository's actual release subjects. The
## upstream Cargo graph is supplemental metadata, never a resolver pin file.
ReleaseSbom := [].{
	Cargo : { components : List(Sbom.Component), relationships : List(Sbom.Edge) }
	FlakeNode : { locked : Try({ owner : Str, repo : Str, rev : Str, narHash : Str }, [Missing]) }
	Native : { source : { sha : Str }, release : Str, repository : Str, artifacts : { all : { sha256 : Str } } }

	## Default reproducible generation context comes from the selected commit,
	## never the wall clock. Four-argument command permits explicit corrections.
	from_git! : Str, Str => Try({}, _)
	from_git! = |root, version| {
		commit = Process.succeed!(Process.command("git", ["rev-parse", "HEAD"], root))?.stdout.trim()
		time = Process.succeed!(Process.command("git", ["show", "-s", "--format=%ct", commit], root))?.stdout.trim()
		epoch = I128.from_str(time).map_err(|_| Invalid("invalid source commit timestamp"))?
		created = Utc.from_millis_since_epoch(epoch * 1000).to_iso_8601()
		run!(root, version, created, commit, "1")
	}

	run! : Str, Str, Str, Str, Str => Try({}, _)
	run! = |root, version, created, commit, revision| {
		if !Integrity.is_hex(commit, 40) {
			return Err(Invalid("source commit must be exact 40-character revision"))
		}
		cargo : Cargo
		cargo = Json.parse(cargo_json).map_err(|_| Invalid("invalid reviewed Cargo graph"))?
		native : Native
		native = Json.parse(native_json.replace_each("\"targets\"", "\"artifacts\"")).map_err(|_| Invalid("invalid linker-input authority"))?
		actual_tag = Path.read_utf8!(Path.utf8("${root}/blueprint-cli/compiler-version"))?
		if actual_tag.trim() != "nightly-2026-10-21-5349569" {
			return Err(Invalid("compiler changed: review full source revision and native closure declaration"))
		}
		if native.source.sha != "5db8f9b9e661f5cbde0254d3520366ef4eab8bd4" {
			return Err(Invalid("native linker authority changed: review supplemental versions/relationships"))
		}
		_ = reviewed_imports!(root)?
		_ = review_cargo!(root, cargo)?
		for released in Release.systems {
			filename = Release.binary_name("blueprint", released.system)
			composition = binary_composition(version, commit, released.system, cargo)?
			write!(root, filename, version, released.system, composition, created, commit, revision)?
		}
		bundles = Path.read_utf8!(Path.utf8("${root}/dist/bundles.txt"))?
		for name in ["roc-blueprint", "roc-blueprint-core", "roc-blueprint-sbom"] {
			filename = Bundle.archive(bundles, name).map_err(|_| Invalid("missing source bundle"))?
			composition = if name == "roc-blueprint-sbom" tool_composition(version, commit, cargo) else source_composition(name, version, commit, native)
			write!(root, filename, version, "source", composition, created, commit, revision)?
		}
		Ok({})
	}

	binary_composition : Str, Str, Str, Cargo -> Try(Sbom.Composition, [Invalid(Str)])
	binary_composition = |version, commit, target, cargo| {
		compiler = Bootstrap.compiler(compiler_version.trim(), target).map_err(|_| Invalid("missing embedded compiler target"))?
		base = component("blueprint", "Blueprint CLI", version, "https://github.com/lukewilliamboswell/roc-blueprint/tree/${commit}", "UPL-1.0", target)
		host = component("basic-cli", "basic-cli", "0.26.0-rc2", "https://github.com/roc-lang/basic-cli/tree/392b1df2856a4944c0fefdfa7dcd8abfdfa2622f", "UPL-1.0", target)
		embedded = { ..component("roc-embedded", "Roc compiler distribution", compiler_version.trim(), compiler.urls.first() ?? "NOASSERTION", "UPL-1.0", target), sha256: compiler.sha256, modified: "Unmodified target archive embedded in executable; checksum describes archive bytes, not extracted roc executable" }
		builder = component("roc-builder", "Roc build compiler", compiler_version.trim(), "https://github.com/roc-lang/roc/tree/534956997e8e5c62888bc14cbc763f60109d0b72", "UPL-1.0", "")
		http = component("http", "roc-lang/http", "1.0.0", "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst", "UPL-1.0", target)
		weaver = component("weaver", "weaver", "0.9.0", "https://github.com/lukewilliamboswell/weaver/releases/download/0.9.0/7j6KBFBEZ8pNMLQHkx9xiwyZ2PmwQPgKNDPUih6gKe77.tar.zst", "NOASSERTION", target)
		crate_components = cargo.components.map(|entry| { ..entry, target })
		crate_edges = crate_components.map(|entry| edge("basic-cli", entry.id, "other", "Available Cargo.lock graph; conditional/build-only membership is not containment evidence"))
		std = component("rust-std", "Rust standard library", "1.97.1", "https://github.com/rust-lang/rust/tree/1.97.1", "MIT OR Apache-2.0", target)
		sqlite = component("sqlite", "SQLite", "3.49.1", "https://www.sqlite.org/2025/sqlite-amalgamation-3490100.zip", "LicenseRef-SQLite-Public-Domain", target)
		sqlite_declared = { ..sqlite, license_url: "https://www.sqlite.org/copyright.html" }
		runtime = if target.ends_with("linux") {
			component("os-runtime", "musl libc", "NOASSERTION", "https://github.com/roc-lang/basic-cli/tree/392b1df2856a4944c0fefdfa7dcd8abfdfa2622f/platform/targets/${if target == "x86_64-linux" "x64musl" else "arm64musl"}", "MIT", target)
		} else if target.ends_with("windows") {
			{ ..component("os-runtime", "Windows UCRT and system DLLs", "NOASSERTION", "NOASSERTION", "LicenseRef-Windows-System-Terms", target), identity: "urn:blueprint:runtime:windows-system-dlls", license_url: "https://www.microsoft.com/licensing/terms/", producer: "Organization: Microsoft" }
		} else {
			{ ..component("os-runtime", "macOS libSystem", "NOASSERTION", "NOASSERTION", "LicenseRef-Apple-System-Terms", target), identity: "urn:blueprint:runtime:macos-libSystem", license_url: "https://www.apple.com/legal/sla/", producer: "Organization: Apple" }
		}
		components = [base, host, embedded, builder, http, weaver, std, sqlite_declared, runtime].concat(crate_components)
		relationships = [
			edge("Subject", base.id, "contains", "Compiled application sources"),
			edge(base.id, host.id, "contains", "Pinned platform native host linked into CLI"),
			edge(base.id, embedded.id, "contains", "compiler-archive List(U8) import"),
			build_dependency("Subject", builder.id, "Release cross compiler, distinct from embedded target archive"),
			edge(base.id, http.id, "contains", "Explicit Roc package import"),
			edge(base.id, weaver.id, "contains", "Explicit Roc package import"),
			edge(host.id, http.id, "dependsOn", "Transitive import in pinned basic-cli main.roc"),
			edge(host.id, std.id, "contains", "Rust staticlib platform host"),
			edge(host.id, runtime.id, if target.ends_with("linux") "contains" else "dependsOn", if target.ends_with("linux") "Platform declares static musl libc inputs; exact libc source version not exposed in upstream asset inventory" else "Native platform invokes runtime libraries supplied by the target operating system; they are external dependencies"),
			edge("cargo-libsqlite3-sys-0.33.0", sqlite.id, "contains", "Bundled feature in pinned Cargo.toml; sqlite3.h in SHA256-verified crate declares 3.49.1"),
		].concat(crate_edges).concat(cargo.relationships)
		coverage = [gap("native-and-compiler-closure", "Roc archive native/compiler dependencies and exact basic-cli Cargo feature/target linkage are not exposed by committed upstream release inventories; Cargo graph is available resolution metadata, not a claim every crate ships"), gap("licenses", "Cargo registry license expressions and compiler distribution constituent notices not fully inventoried; NOASSERTION retained explicitly")]
		Ok({ profile: Sbom.profile, imported_documents: [], unavailable_sboms: [], components, relationships, coverage, inputs: [] })
	}

	tool_composition : Str, Str, Cargo -> Sbom.Composition
	tool_composition = |version, commit, cargo| {
		own = component("sources", "roc-blueprint-sbom", version, "https://github.com/lukewilliamboswell/roc-blueprint/tree/${commit}/scripts", "UPL-1.0", "")
		core = component("core", "roc-blueprint-core", version, "https://github.com/lukewilliamboswell/roc-blueprint/tree/${commit}/blueprint-core", "UPL-1.0", "")
		compiler = component("roc-builder", "Roc source-app compiler", compiler_version.trim(), "https://github.com/roc-lang/roc/tree/534956997e8e5c62888bc14cbc763f60109d0b72", "UPL-1.0", "")
		host = component("basic-cli", "basic-cli", "0.26.0-rc2", "https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc2/Gj3zVDr3qrQa6aTh7Z1zgUfe9NeBE6R76T5ho3xrc8af.tar.zst", "UPL-1.0", "")
		http = component("http", "roc-lang/http", "1.0.0", "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst", "UPL-1.0", "")
		sqlite = { ..component("sqlite", "SQLite", "3.49.1", "https://www.sqlite.org/2025/sqlite-amalgamation-3490100.zip", "LicenseRef-SQLite-Public-Domain", ""), license_url: "https://www.sqlite.org/copyright.html" }
		std = component("rust-std", "Rust standard library", "1.97.1", "https://github.com/rust-lang/rust/tree/1.97.1", "MIT OR Apache-2.0", "")
		{
			profile: Sbom.profile,
			imported_documents: [],
			unavailable_sboms: [],
			components: [own, core, compiler, host, http, sqlite, std].concat(cargo.components),
			relationships: [edge("Subject", own.id, "contains", "Exactly scripts/sbom.roc and src/SbomFiles.roc; staged main filename and dependency/compiler pins only"), edge(own.id, core.id, "dependsOn", "Released core bundle, fetched separately by Roc"), edge(own.id, host.id, "dependsOn", "Pinned native CLI platform, fetched separately by Roc"), edge(host.id, http.id, "dependsOn", "Pinned platform imports the HTTP package"), build_dependency("Subject", compiler.id, "roc bundle produces the delivered source-app archive"), edge(own.id, compiler.id, "dependsOn", "App source requires the explicit matching compiler to run"), edge(host.id, std.id, "contains", "Platform bundle distributes Rust staticlib native hosts"), edge("cargo-libsqlite3-sys-0.33.0", sqlite.id, "contains", "Pinned bundled SQLite source in verified Rust crate")].concat(cargo.components.map(|entry| edge(host.id, entry.id, "other", "Upstream platform Cargo resolution candidate; native target/features/role unresolved"))).concat(cargo.relationships),
			coverage: [gap("upstream-platform-closure", "App ships only its wrapper/I/O source and fetches core/basic-cli later; available Cargo graph retained, exact native target/feature/license closure remains incomplete")],
			inputs: [],
		}
	}

	source_composition : Str, Str, Str, Native -> Sbom.Composition
	source_composition = |name, version, commit, native| {
		own = component("sources", name, version, "https://github.com/lukewilliamboswell/roc-blueprint/tree/${commit}/${if name == "roc-blueprint" "blueprint-platform" else "blueprint-core"}", "UPL-1.0", "")
		compiler = component("roc-builder", "Roc bundle compiler", compiler_version.trim(), "https://github.com/roc-lang/roc/tree/534956997e8e5c62888bc14cbc763f60109d0b72", "UPL-1.0", "")
		base = [own, compiler]
		edges = [edge("Subject", own.id, "contains", "Source files in content-addressed Roc bundle"), build_dependency("Subject", compiler.id, "roc bundle generates archive; compiler not shipped in source bundle")]
		if name == "roc-blueprint-core" {
			{ profile: Sbom.profile, imported_documents: [], unavailable_sboms: [], components: base, relationships: edges, coverage: [{ scope: "roc-import-closure", status: "complete", reason: "Core imports only first-party modules and Roc builtins; compiler supplied separately", contact }], inputs: [] }
		} else {
			inputs_base = component("linker-inputs", "Roc/Zig linker-input archive", native.source.sha, "https://github.com/${native.repository}/releases/download/${native.release}/link-inputs-all.tar", "NOASSERTION", "")
			inputs = { ..inputs_base, sha256: native.artifacts.all.sha256 }
			musl = component("musl", "musl libc", "1.2.5", "https://musl.libc.org/releases/musl-1.2.5.tar.gz", "MIT", "")
			zig = component("zig-runtime", "Zig compiler runtime", "0.17.0", "https://github.com/ziglang/zig/tree/0.17.0", "MIT", "")
			core = component("core", "roc-blueprint-core", version, "https://github.com/lukewilliamboswell/roc-blueprint/tree/${commit}/blueprint-core", "UPL-1.0", "")
			msvc = component("msvc-runtime", "Roc MSVC startup runtime", "7d256b954603e1170ee0d6df229c795aba6dc70d", "https://github.com/roc-lang/roc/tree/7d256b954603e1170ee0d6df229c795aba6dc70d/src/default_platform/msvc_runtime", "UPL-1.0", "")
			windows_os = { ..component("windows-os", "Windows system DLLs", "NOASSERTION", "NOASSERTION", "LicenseRef-Windows-System-Terms", ""), identity: "urn:blueprint:runtime:windows-system-dlls", license_url: "https://www.microsoft.com/licensing/terms/", producer: "Organization: Microsoft" }
			macos_os = { ..component("macos-os", "macOS libSystem", "NOASSERTION", "NOASSERTION", "LicenseRef-Apple-System-Terms", ""), identity: "urn:blueprint:runtime:macos-libSystem", license_url: "https://www.apple.com/legal/sla/", producer: "Organization: Apple" }
			{ profile: Sbom.profile, imported_documents: [], unavailable_sboms: [], components: base.concat([inputs, musl, zig, core, msvc, windows_os, macos_os]), relationships: edges.concat([edge(inputs.id, own.id, "generates", "Platform source bundle includes verified extracted members, not the original input archive bytes"), edge(inputs.id, musl.id, "contains", "Pinned producer runtime/sources.json musl_version"), edge(inputs.id, zig.id, "contains", "Pinned producer runtime/sources.json zig_version"), edge(inputs.id, msvc.id, "contains", "Pinned producer linker-inputs/msvc-runtime/UPSTREAM.json"), edge(own.id, core.id, "dependsOn", "Platform references sibling core bundle, fetched later by Roc"), edge(msvc.id, windows_os.id, "dependsOn", "Windows import libraries reference system-provided DLLs; OS bytes are not shipped"), edge(own.id, macos_os.id, "dependsOn", "Bundled macOS native hosts call system-provided libSystem; its version remains unknown")]), coverage: [gap("native-closure", "Known Linux static runtimes and Windows startup included; Windows import library OS dependencies and compiler-generated host closure require deeper upstream metadata")], inputs: [] }
		}
	}
}

contact = "https://github.com/lukewilliamboswell/roc-blueprint/issues"

gap = |scope, reason| { scope, status: "incomplete", reason, contact }

component : Str, Str, Str, Str, Str, Str -> Sbom.Component
component = |id, name, version, download, license, target| { id: "${id}", name, producer: if download.contains("github.com/roc-lang/") "Organization: Roc contributors" else if download.contains("github.com/lukewilliamboswell/") "Person: Luke Boswell" else "NOASSERTION", version, identity: "${download}#${version}", download, sha256: "", license, license_url: "", modified: "", target, origin: "reviewed" }

edge : Str, Str, Str, Str -> Sbom.Edge
edge = |from, to, relation, basis| { from, to, relation, scope: "", basis }

## `subject` needs `tool` to be built: SPDX 2.3 `BUILD_DEPENDENCY_OF`.
build_dependency : Str, Str, Str -> Sbom.Edge
build_dependency = |subject, tool, basis| { from: subject, to: tool, relation: "dependsOn", scope: "build", basis }

write! = |root, filename, version, target, composition, created, commit, revision| {
	# The recipe observes release authorities directly; it has no Blueprint Lock.
	observed = reviewed_imports!(root)?
	var $inputs = []
	cargo : ReleaseSbom.Cargo
	cargo = Json.parse(cargo_json).map_err(|_| Invalid("invalid Cargo graph"))?
	for crate in cargo.components {
		$inputs = $inputs.append({ input: "cargo:${crate.name}@${crate.version}:${crate.sha256}", component: if composition.components.any(|entry| entry.id == crate.id) crate.id else "", reason: if !composition.components.any(|entry| entry.id == crate.id) "CLI/release-script runtime resolution candidate excluded from this source software's import closure" else "Pinned upstream Cargo resolution candidate; exact runtime/build/target role recorded separately or incomplete" })
	}
	if composition.components.any(|entry| entry.name == "roc-blueprint-sbom") {
		tool_imports = reviewed_tool_imports!(root)?
		for entry in tool_imports {
			$inputs = $inputs.append({ input: "tool-import:${entry.url}", component: entry.component, reason: "Observed standalone wrapper import; staged core URL uses the separately hashed released core bundle" })
		}
		for source in ["scripts/sbom.roc", "scripts/src/SbomFiles.roc"] {
			sha = SbomFiles.digest!("${root}/${source}")?
			$inputs = $inputs.append({ input: "tool-source:${source}:${sha}", component: "sources", reason: "Exact copied wrapper/I/O source; only entry filename and core/compiler metadata are staged" })
		}
	}
	for entry in observed {
		component_id = if target == "source" "" else entry.component
		$inputs = $inputs.append({ input: "roc-import:${entry.url}", component: component_id, reason: if target == "source" "CLI import excluded from this separate source-bundle subject" else "Observed CLI package declaration; reviewed composition identifies its role" })
	}
	own_id = if target == "source" "sources" else "blueprint"
	$inputs = $inputs.append({ input: "source-revision:${commit}", component: own_id, reason: "First-party source revision selected for this build" })
	$inputs = $inputs.append({ input: "build-compiler:${compiler_version.trim()}", component: "roc-builder", reason: "Exact compiler is a build input independent of embedded target archive" })
	if target != "source" {
		archive = Bootstrap.compiler(compiler_version.trim(), target).map_err(|_| Invalid("unknown compiler target"))?
		$inputs = $inputs.append({ input: "embedded-archive:${target}:${archive.sha256}", component: "roc-embedded", reason: "Bootstrap table authorizes embedded target archive bytes; not extracted executable digest" })
	}
	native : ReleaseSbom.Native
	native = Json.parse(native_json.replace_each("\"targets\"", "\"artifacts\"")).map_err(|_| Invalid("invalid linker-input authority"))?
	native_id = if composition.components.any(|entry| entry.id == "linker-inputs") "linker-inputs" else ""
	$inputs = $inputs.append({ input: "linker-archive:${native.artifacts.all.sha256}", component: native_id, reason: if native_id.is_empty() "Separate Blueprint platform linker inputs do not ship in this subject" else "Verified archive selected by committed link-inputs.lock.json" })
	$inputs = $inputs.append({ input: "platform-core-dependency:../blueprint-core/main.roc", component: if composition.components.any(|entry| entry.id == "core") "core" else "", reason: "Platform uses sibling core source bundle; unrelated subjects exclude this dependency" })
	flake : { nodes : Dict(Str, ReleaseSbom.FlakeNode) }
	flake = Json.parse(flake_lock_json).map_err(|_| Invalid("invalid flake.lock"))?
	var $tool_components = []
	var $tool_edges = []
	for pair in flake.nodes.to_list() {
		match pair.1.locked {
			Ok(pin) => {
				id = "build-source-${pair.0}"
				input = "build-source:${pair.0}:${pin.rev}:${pin.narHash}"
				tool = { ..component("build-source-${pair.0}", "${pin.owner}/${pin.repo}", pin.rev, "https://github.com/${pin.owner}/${pin.repo}/tree/${pin.rev}", "NOASSERTION", ""), identity: "https://github.com/${pin.owner}/${pin.repo}/tree/${pin.rev}#${pin.narHash}" }
				$tool_components = $tool_components.append(tool)
				$tool_edges = $tool_edges.append(build_dependency("Subject", id, "Build environment source tree pin; NAR hash is not an archive SHA256"))
				$inputs = $inputs.append({ input, component: id, reason: "Committed flake.lock build input; does not establish containment" })
			}
			Err(Missing) => {}
		}
	}
	var $delivered_components = composition.components
	var $delivered_edges = composition.relationships
	if composition.components.any(|entry| entry.id == "core") {
		bundles = Path.read_utf8!(Path.utf8("${root}/dist/bundles.txt"))?
		core_filename = Bundle.archive(bundles, "roc-blueprint-core").map_err(|_| Invalid("missing core source bundle"))?
		core_sha = SbomFiles.digest!("${root}/dist/${core_filename}")?
		$delivered_components = $delivered_components.map(|entry| if entry.id == "core" { ..entry, download: Bundle.release_url(Bundle.default_repository, version, core_filename), sha256: core_sha, identity: "urn:blueprint:source-bundle:${core_filename}:${core_sha}" } else entry)
	}
	if composition.components.any(|entry| entry.id == "linker-inputs") {
		platform_source = Path.read_utf8!(Path.utf8("${root}/blueprint-platform/main.roc"))?
		members = Bundle.target_inputs(platform_source).map_err(|_| Invalid("platform recipe has no declared linker members"))?
		for member in members {
			member_sha = SbomFiles.digest!("${root}/blueprint-platform/${member}")?
			member_id = "member-${member.replace_each("/", "-").replace_each("_", "-")}"
			member_target = match (member.split_on("/").get(1) ?? "") {
				"x64musl" => "x86_64-linux"
				"arm64musl" => "aarch64-linux"
				"x64mac" => "x86_64-darwin"
				"arm64mac" => "aarch64-darwin"
				"x64win" => "x86_64-windows"
				other => other
			}
			member_component = { ..component("member-${member.replace_each("/", "-").replace_each("_", "-")}", member, "sha256-${member_sha}", "NOASSERTION", "NOASSERTION", member_target), sha256: member_sha, identity: "urn:blueprint:linker-member:${member}:${member_sha}", modified: "Member ${member} in ${Bundle.release_url(Bundle.default_repository, version, filename)}; checksum names member bytes, not containing archive" }
			$delivered_components = $delivered_components.append(member_component)
			$delivered_edges = $delivered_edges.append(edge("sources", member_id, "contains", "Exact member named by Bundle.target_inputs and copied into platform source bundle; digest is member bytes"))
			if member.ends_with("/libc.a") or member.ends_with("/crt1.o") {
				$delivered_edges = $delivered_edges.append(edge(member_id, "musl", "contains", "Pinned runtime producer identifies musl source 1.2.5"))
			} else if member.ends_with("/libzigc.a") or member.ends_with("/libcompiler_rt.a") {
				$delivered_edges = $delivered_edges.append(edge(member_id, "zig-runtime", "contains", "Pinned runtime producer identifies Zig runtime source 0.17.0"))
			} else if member.ends_with("/msvc_runtime.lib") {
				$delivered_edges = $delivered_edges.append(edge(member_id, "msvc-runtime", "contains", "Pinned producer retains original Roc startup source revision"))
			}
			origin_id = if member.ends_with("/libhost.a") or member.ends_with("/host.lib") "sources" else "linker-inputs"
			$delivered_edges = $delivered_edges.append(edge(origin_id, member_id, "generates", "First-party host or verified extracted upstream archive member; different byte identities remain separate"))
			$inputs = $inputs.append({ input: "platform-member:${member}:${member_sha}", component: member_id, reason: "Actual recipe-declared delivered linker member; input archive hash is recorded separately" })
		}
	}
	if target == "source" {
		# The produced archive, not the bundler's argument list, says what a
		# source bundle holds: `roc bundle` packs the files its modules import
		# too. Every member is stated by digest; a declared linker member is
		# an archive member as well, and stays one component.
		members = SbomFiles.archive_members!("${root}/dist/${filename}")?
		archive = Sbom.archive_members("sources", members).map_err(|message| Invalid(message))?
		for member_component in archive.components {
			match $delivered_components.find_first(|entry| entry.id == member_component.id) {
				Ok(declared) =>
					if declared.sha256 != member_component.sha256 {
						return Err(Invalid("archive member ${member_component.name} differs from the declared linker member"))
					}
				Err(_) => {
					$delivered_components = $delivered_components.append(member_component)
					$delivered_edges = $delivered_edges.concat(archive.relationships.keep_if(|relation| relation.to == member_component.id))
				}
			}
		}
		Sbom.members_accounted(members, { ..composition, components: $delivered_components, inputs: $inputs }).map_err(|message| Invalid(message))?
	}
	inventory = Sbom.inspect_declared(target, { ..composition, components: $delivered_components.concat($tool_components), relationships: $delivered_edges.concat($tool_edges), inputs: $inputs }, $inputs.map(|entry| entry.input)).map_err(|message| Invalid(message))?
	measured = SbomFiles.measure!("${root}/dist/${filename}")?
	digest = measured.sha256
	subject = { filename, version, target, sha256: digest, url: Bundle.release_url(Bundle.default_repository, version, filename) }
	context = { namespace: "https://github.com/${Bundle.default_repository}/sbom/${commit}/${filename}/revision-${revision}", revision, created, author: "Organization: Roc Blueprint contributors", generator: "Tool: blueprint-sbom-0.7.0" }
	text = Sbom.render(inventory, subject, context).map_err(|message| Invalid(message))?
	SbomFiles.write_new!("${root}/dist/${filename}.spdx.json", text)?
	Stdout.line!("${filename}.spdx.json")?
	# The same inventory for consumers that read only SPDX 2.
	text_2 = Sbom.render_spdx2(inventory, subject, context).map_err(|message| Invalid(message))?
	SbomFiles.write_new!("${root}/dist/${filename}.spdx-2.3.json", text_2)?
	Stdout.line!("${filename}.spdx-2.3.json")?
	# And for security tooling that reads CycloneDX.
	bom = Sbom.render_cyclonedx(inventory, subject, context).map_err(|message| Invalid(message))?
	SbomFiles.write_new!("${root}/dist/${filename}.cdx.json", bom)?
	Stdout.line!("${filename}.cdx.json")?
	# The inventory the sidecars were bound from, as `inspect` would write it,
	# stays in dist/ for the independent check; the evidence manifest beside
	# the sidecars ties them to it and to the subject by digest and size.
	inventory_text = "${Json.to_str(inventory)}\n"
	SbomFiles.write_new!("${root}/dist/${filename}.inventory.json", inventory_text)?
	listed = |name, format, content| { filename: "${filename}${name}", format, sha256: Integrity.digest(content.to_utf8()), size: content.to_utf8().len() }
	manifest = Manifest.render({
		profile: Sbom.profile,
		subject: { filename, version, target, sha256: digest, size: measured.size },
		inventory_sha256: Integrity.digest(inventory_text.to_utf8()),
		context: { namespace: context.namespace, revision, created, generator: context.generator },
		sidecars: [listed(".spdx.json", "spdx-3.0.1", text), listed(".spdx-2.3.json", "spdx-2.3", text_2), listed(".cdx.json", "cyclonedx-1.7", bom)],
	}).map_err(|message| Invalid(message))?
	SbomFiles.write_new!("${root}/dist/${filename}${Manifest.suffix}", manifest)?
	Stdout.line!("${filename}${Manifest.suffix}")
}

# Fail closed on new or changed imports: availability/composition changes must
# be reviewed alongside this recipe. This evidence is exported in annotations.
reviewed_imports! : Str => Try(List({ url : Str, component : Str }), _)
reviewed_imports! = |root| {
	cli_source = Path.read_utf8!(Path.utf8("${root}/blueprint-cli/main.roc"))?
	platform_source = Path.read_utf8!(Path.utf8("${root}/blueprint-platform/main.roc"))?
	core_source = Path.read_utf8!(Path.utf8("${root}/blueprint-core/main.roc"))?
	header = cli_source.split_on("\n}\n").first() ?? ""
	observed = header.split_on("\n").keep_if(|line| !line.trim().starts_with("#") and line.contains(": ")).map(|line| line.split_on("\"").get(1) ?? "")
	expected = [
		{ url: "../blueprint-core/main.roc", component: "blueprint" },
		{ url: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst", component: "http" },
		{ url: "../blueprint-nix/main.roc", component: "blueprint" },
		{ url: "https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc2/Gj3zVDr3qrQa6aTh7Z1zgUfe9NeBE6R76T5ho3xrc8af.tar.zst", component: "basic-cli" },
		{ url: "https://github.com/lukewilliamboswell/weaver/releases/download/0.9.0/7j6KBFBEZ8pNMLQHkx9xiwyZ2PmwQPgKNDPUih6gKe77.tar.zst", component: "weaver" },
	]
	if observed != expected.map(|entry| entry.url) {
		return Err(Invalid("CLI imports changed: review SBOM composition, do not silently omit new inputs"))
	}
	if !platform_source.contains("core: \"../blueprint-core/main.roc\"") or !core_source.trim().ends_with("{}") {
		return Err(Invalid("source bundle dependencies changed: review SBOM composition"))
	}
	Ok(expected)
}

# Independently check the reviewed supplemental graph against its original
# upstream lock. Dropping a package or edge is an error, not an empty closure.
review_cargo! : Str, ReleaseSbom.Cargo => Try({}, _)
review_cargo! = |root, cargo| {
	text = SbomFiles.read!("${root}/sbom/upstream/basic-cli-Cargo.lock")?
	verify_cargo(text, cargo)
}

verify_cargo : Str, ReleaseSbom.Cargo -> Try({}, [Invalid(Str)])
verify_cargo = |text, cargo| {
	if Integrity.digest(text.to_utf8()) != "a4e9ab23a342911a43c815ef752a196788fc09bd8130ffb2f82f5794874d9aca" {
		return Err(Invalid("upstream Cargo lock changed: review composition provenance"))
	}
	blocks = text.split_on("[[package]]").drop_first(1)
	var $known = []
	var $edge_count = 0.U64
	for block in blocks {
		name = toml_field(block, "name")
		version = toml_field(block, "version")
		if name != "roc_host" {
			entry = cargo.components.find_first(|candidate| candidate.name == name and candidate.version == version).map_err(|_| Invalid("known Cargo component omitted: ${name}@${version}"))?
			if entry.sha256 != toml_field(block, "checksum") or entry.identity != "pkg:cargo/${name}@${version}" {
				return Err(Invalid("Cargo component identity conflicts with upstream pin"))
			}
			$known = $known.append(entry.id)
			dependencies = block.split_on("dependencies = [").get(1).map_ok(|tail| tail.split_on("]").first() ?? "") ?? ""
			for line in dependencies.split_on("\n").keep_if(|line| line.trim().starts_with("\"")) {
				ref = line.split_on("\"").get(1) ?? ""
				parts = ref.split_on(" ")
				dep_name = parts.first() ?? ""
				dep_version = parts.get(1) ?? ""
				candidates = cargo.components.keep_if(|candidate| candidate.name == dep_name and (dep_version.is_empty() or candidate.version == dep_version))
				if candidates.len() != 1 {
					return Err(Invalid("ambiguous/missing Cargo dependency"))
				}
				dependency = candidates.first().map_err(|_| Invalid("missing dependency"))?
				if !cargo.relationships.any(|relation| relation.from == entry.id and relation.to == dependency.id) {
					return Err(Invalid("known Cargo graph edge omitted"))
				}
				$edge_count = $edge_count + 1
			}
		}
	}
	if $known.len() != cargo.components.len() or $edge_count != cargo.relationships.len() {
		return Err(Invalid("Cargo graph has unexplained extra identities/edges"))
	}
	Ok({})
}

toml_field : Str, Str -> Str
toml_field = |text, key| {
	line = text.split_on("\n").find_first(|candidate| candidate.starts_with("${key} = \"")) ?? ""
	line.split_on("\"").get(1) ?? ""
}

reviewed_cargo : ReleaseSbom.Cargo
reviewed_cargo = Json.parse(cargo_json) ?? crash "invalid reviewed graph"
expect verify_cargo(cargo_lock_fixture, reviewed_cargo).is_ok()
expect verify_cargo(cargo_lock_fixture, { ..reviewed_cargo, components: reviewed_cargo.components.drop_first(1) }).is_err()
expect verify_cargo(cargo_lock_fixture, { ..reviewed_cargo, relationships: reviewed_cargo.relationships.drop_first(1) }).is_err()
expect verify_cargo(cargo_lock_fixture, { ..reviewed_cargo, components: reviewed_cargo.components.map(|entry| { ..entry, sha256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }) }).is_err()

reviewed_tool_imports! : Str => Try(List({ url : Str, component : Str }), _)
reviewed_tool_imports! = |root| {
	source = SbomFiles.read!("${root}/scripts/sbom.roc")?
	header = source.split_on("\n}\n").first() ?? ""
	observed = header.split_on("\n").keep_if(|line| !line.trim().starts_with("#") and !line.trim().starts_with("roc:") and line.contains(": ")).map(|line| line.split_on("\"").get(1) ?? "")
	expected = [{ url: "https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc2/Gj3zVDr3qrQa6aTh7Z1zgUfe9NeBE6R76T5ho3xrc8af.tar.zst", component: "basic-cli" }, { url: "../blueprint-core/main.roc", component: "core" }]
	if observed != expected.map(|entry| entry.url) {
		return Err(Invalid("standalone SBOM wrapper imports changed: review composition"))
	}
	Ok(expected)
}

# Every reviewed composition is a valid inventory under the current profile,
# before the observed inputs that `write!` adds.
reviewed_native : ReleaseSbom.Native
reviewed_native = Json.parse(native_json.replace_each("\"targets\"", "\"artifacts\"")) ?? crash "invalid linker-input authority"

commit_fixture = "1111111111111111111111111111111111111111"

inspects = |target, composition| Sbom.inspect_declared(target, composition, []).is_ok()
expect Release.systems.all(
	|released|
		match ReleaseSbom.binary_composition("0.7.0", commit_fixture, released.system, reviewed_cargo) {
			Ok(composition) => inspects(released.system, composition)
			Err(_) => False
		},
)
expect inspects("source", ReleaseSbom.tool_composition("0.7.0", commit_fixture, reviewed_cargo))
expect ["roc-blueprint", "roc-blueprint-core"].all(|name| inspects("source", ReleaseSbom.source_composition(name, "0.7.0", commit_fixture, reviewed_native)))
