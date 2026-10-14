import core.Lock
import Download

## What the release that serves a download says its digest is. Only
## `blueprint update` asks: a digest it computed itself is compared with the
## published one, and a download for a system it does not run on is recorded
## by the published digest without being fetched. A run never asks: by then
## the Lock holds the digest, and nothing later changes it.
##
## The question goes to the releases API of the host that serves the asset,
## with no token and nothing else that identifies the caller: what is asked
## about is public. An answer is not trusted more than the download is. It is
## a second witness from the same publisher over another path, and the Lock
## records which witnesses a digest had.
Published := [].{

	## A release asset, by the URL it is downloaded from: where its release
	## is described, and the name the release lists it under.
	Release : { api : Str, repository : Str, tag : Str, asset : Str }

	## The release a download URL is an asset of, when the URL is a GitHub
	## release asset, `https://github.com/<owner>/<repo>/releases/download/<tag>/<asset>`.
	## A URL of the same shape on the loopback address is one too, described
	## by the same server: that is how a test serves a release, as it serves
	## a download.
	release : Str -> Try(Release, [NotAReleaseAsset])
	release = |url| {
		(api, rest) = if url.starts_with("https://github.com/") {
			("https://api.github.com", url.drop_prefix("https://github.com/"))
		} else if Download.loopback(url) {
			server = Download.origin(url)
			(server, url.drop_prefix("${server}/"))
		} else {
			return Err(NotAReleaseAsset)
		}
		match rest.split_on("/") {
			[owner, repo, "releases", "download", tag, asset] =>
				if [owner, repo, tag, asset].any(|part| part.is_empty()) {
					Err(NotAReleaseAsset)
				} else {
					Ok({ api: "${api}/repos/${owner}/${repo}/releases/tags/${tag}", repository: "${owner}/${repo}", tag, asset })
				}

			_ => Err(NotAReleaseAsset)
		}
	}

	## The SHA-256 and length a release's description gives for one of its
	## assets. `NotPublished`: the release does not list the asset, or lists
	## it with no SHA-256, as GitHub does for an asset uploaded before it
	## recorded digests. `Unreadable`: the text is not a release's
	## description at all, which an error page is not.
	digest : Str, Str -> Try(Lock.Digest, [NotPublished, Unreadable])
	digest = |text, asset| {
		# The JSON reader has no value for `null` in a text field: an asset
		# with no digest is read as one with an empty digest.
		parsed : Try({ assets : List({ name : Str, size : U64, digest : Try(Str, [Missing]) }) }, _)
		parsed = Json.parse(text.replace_each("\"digest\": null", "\"digest\": \"\"").replace_each("\"digest\":null", "\"digest\":\"\""))
		listed = parsed.map_err(|_| Unreadable)?
		found = listed.assets.find_first(|entry| entry.name == asset).map_err(|_| NotPublished)?
		reported = found.digest ?? ""
		hex = reported.drop_prefix("sha256:")
		if reported.starts_with("sha256:") and hex.to_utf8().len() == 64 and hex.to_utf8().all(|b| (b >= '0' and b <= '9') or (b >= 'a' and b <= 'f')) {
			Ok({ sha256: hex, size: found.size })
		} else {
			Err(NotPublished)
		}
	}

	## What to say when a release could not be asked about. Nothing stops:
	## what a release publishes is a second witness, and an update that lacks
	## it hashes every download itself, as it does for a host that publishes
	## nothing. The service answers a limited number of unidentified requests,
	## and that limit is the usual reason, so the message says what it is.
	notice : Release, U16, Str -> Str
	notice = |asked, status, reason| {
		limited = if status == 403 or status == 429 {
			" GitHub answers 60 such requests an hour from one address when no token is sent, and blueprint sends none."
		} else {
			""
		}
		"could not ask for the digests ${asked.repository} publishes for its release ${asked.tag}: ${reason}.${limited} The digests of its downloads are computed by downloading each of them instead, and Blueprint.lock records them as computed"
	}

	## The description of a release, as its host gives it now. `NoRelease`:
	## the host knows no release with that tag, so nothing is published for
	## its assets. `Unanswered`: the host refused, could not be reached, or
	## sent what is not a release's description; it carries the notice to
	## print. In both cases the caller has no published digest and computes
	## every one. A digest that is published is never set aside this way: one
	## that differs from the computed digest still stops the update.
	ask! : Release => [Described(Str), NoRelease, Unanswered(Str)]
	ask! = |asked|
		match Download.asked!(asked.api, [("User-Agent", "blueprint"), ("Accept", "application/vnd.github+json")]) {
			Ok(bytes) =>
				match Str.from_utf8(bytes) {
					Ok(text) => if digest(text, asked.asset) == Err(Unreadable) Unanswered(notice(asked, 200, "the answer from ${asked.api} does not describe a release")) else Described(text)
					Err(_) => Unanswered(notice(asked, 200, "the answer from ${asked.api} is not text"))
				}

			Err({ status: 404, .. }) => NoRelease
			Err({ status, reason }) => Unanswered(notice(asked, status, reason))
		}
}

nightly : Str
nightly = "https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-04-130536d/roc_nightly-linux_x86_64-2026-10-04-130536d.tar.gz"

# A GitHub release asset names its repository, tag and asset, and is
# described by the releases API of that repository.
expect Published.release(nightly) == Ok({ api: "https://api.github.com/repos/roc-lang/nightlies/releases/tags/nightly-2026-10-04-130536d", repository: "roc-lang/nightlies", tag: "nightly-2026-10-04-130536d", asset: "roc_nightly-linux_x86_64-2026-10-04-130536d.tar.gz" })

# On the loopback address the same server describes the release.
expect Published.release("http://127.0.0.1:4000/owner/tool/releases/download/1.0/tool-x86_64-linux") == Ok({ api: "http://127.0.0.1:4000/repos/owner/tool/releases/tags/1.0", repository: "owner/tool", tag: "1.0", asset: "tool-x86_64-linux" })

# Nothing else is a release asset: another host, another path on GitHub, a
# source archive, a path with a part missing or one too many.
expect
	[
		"https://example.org/owner/tool/releases/download/1.0/tool",
		"https://github.com.example.org/owner/tool/releases/download/1.0/tool",
		"https://raw.githubusercontent.com/owner/tool/main/tool",
		"https://github.com/owner/tool/archive/refs/tags/1.0.tar.gz",
		"https://github.com/owner/tool/releases/download/1.0",
		"https://github.com/owner/tool/releases/download//tool",
		"https://github.com/owner/tool/releases/download/1.0/dir/tool",
		"https://github.com/owner/tool/releases/latest/download/tool",
		"http://127.0.0.1:4000/tool-x86_64-linux",
		"http://github.com/owner/tool/releases/download/1.0/tool",
		"",
	].all(|url| Published.release(url) == Err(NotAReleaseAsset))

# As GitHub writes a release: spaced, with fields nothing here reads, a
# `null` where an older asset has no digest, and other algorithms.
described : Str
described =
	\\{
	\\  "tag_name": "1.0",
	\\  "body": null,
	\\  "assets": [
	\\    { "name": "tool-x86_64-linux", "label": null, "size": 5900520, "digest": "sha256:2c083762ce177e407730eaa41a8257631969341716950252df3c9fefd2b070aa" },
	\\    { "name": "tool-aarch64-darwin", "size": 4094240, "digest": "sha256:f3a4d05bc894ab22114cf85b6815c0862ce67321d61b75fc1d538c573ab65087" },
	\\    { "name": "old", "size": 3, "digest": null },
	\\    { "name": "bare", "size": 3 },
	\\    { "name": "short", "size": 3, "digest": "sha256:2c08" },
	\\    { "name": "other", "size": 3, "digest": "sha512:2c083762ce177e407730eaa41a8257631969341716950252df3c9fefd2b070aa" }
	\\  ]
	\\}

expect Published.digest(described, "tool-x86_64-linux") == Ok({ sha256: "2c083762ce177e407730eaa41a8257631969341716950252df3c9fefd2b070aa", size: 5900520 })
expect Published.digest(described, "tool-aarch64-darwin") == Ok({ sha256: "f3a4d05bc894ab22114cf85b6815c0862ce67321d61b75fc1d538c573ab65087", size: 4094240 })
expect Published.digest(described.replace_each("\": ", "\":").replace_each("\n", "").replace_each(" ", ""), "tool-x86_64-linux").map_ok(|found| found.size) == Ok(5900520)

# An asset the release does not list, or lists with no SHA-256, has nothing
# published: that is an answer, and the download is hashed instead.
expect ["absent", "old", "bare", "short", "other"].all(|asset| Published.digest(described, asset) == Err(NotPublished))

# What is not a release's description is not read as one with no digests.
expect Published.digest("{\"message\":\"API rate limit exceeded\"}", "tool-x86_64-linux") == Err(Unreadable)
expect Published.digest("<html>", "tool-x86_64-linux") == Err(Unreadable) and Published.digest("", "tool-x86_64-linux") == Err(Unreadable)

# A question that was refused says what happened and what is done instead;
# when it is the service's limit, also what the limit is.
expect {
	asked = { api: "https://api.github.com/repos/owner/tool/releases/tags/1.0", repository: "owner/tool", tag: "1.0", asset: "tool" }
	Published.notice(asked, 403, "HTTP 403 from https://api.github.com/repos/owner/tool/releases/tags/1.0 (1 attempt)") == "could not ask for the digests owner/tool publishes for its release 1.0: HTTP 403 from https://api.github.com/repos/owner/tool/releases/tags/1.0 (1 attempt). GitHub answers 60 such requests an hour from one address when no token is sent, and blueprint sends none. The digests of its downloads are computed by downloading each of them instead, and Blueprint.lock records them as computed"
		and Published.notice(asked, 429, "x").contains("60 such requests an hour")
			and !Published.notice(asked, 0, "could not reach https://api.github.com/x (3 attempts)").contains("60 such requests")
				and Published.notice(asked, 500, "x").contains("computed by downloading each of them instead")
}
