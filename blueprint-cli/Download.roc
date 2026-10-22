import pf.Http
import pf.Sleep
import http.Request
import http.Response

## Downloads in this process, over HTTPS. A request carries no token, cookie
## or other credential, whatever the caller's environment holds: what is
## fetched is public, and its bytes are checked against a digest by the
## caller, so nothing here has to be trusted and nothing is ever sent.
Download := [].{

	## The body `url` serves, following redirects. Each URL is tried up to
	## three times when the transfer fails or the server says to come back; a
	## refusal such as 404 is final at once. The error says what happened
	## last and how often it was tried.
	##
	## The whole body is held in memory: the platform has no streaming
	## client. A download of 70 MB peaks near twice that.
	get! : Str => Try(List(U8), Str)
	get! = |url| served!(url).map_ok(|answer| answer.bytes)

	## `get!`, with the address that served the body in the end: `url`
	## itself, or where its redirects led, which may be another host. The
	## caller can record that host. The address itself is not one to print or
	## keep: a release host signs the one it redirects to.
	served! : Str => Try({ bytes : List(U8), url : Str }, Str)
	served! = |url| attempt!(url, [], 1).map_err(|failure| failure.reason)

	## `get!` with request headers that say who asks, such as a `User-Agent`
	## a service requires, and an answer that keeps the status of a refusal
	## apart from its words: 0 when no answer came at all. A header is never
	## a credential, and is sent to the first address alone: a redirect is
	## followed without it.
	asked! : Str, List((Str, Str)) => Try(List(U8), { status : U16, reason : Str })
	asked! = |url, headers| attempt!(url, headers, 1).map_ok(|answer| answer.bytes)

	## How many times one URL is tried.
	attempts : U64
	attempts = 3

	## A redirect is followed at most this many times.
	max_hops : U64
	max_hops = 5

	## The whole request and response of one hop, in milliseconds.
	timeout_ms : U64
	timeout_ms = 300_000

	## Where a redirect from a declared URL may lead. A hop is HTTPS, and may
	## carry a query: a release host signs the address it redirects to. Plain
	## HTTP is followed only to the loopback address and only from a URL that
	## was itself declared there, which is how a test serves a download. A
	## hop never names credentials. A `Location` that starts at `/` is on the
	## host that sent it.
	hop : Str, Str, Str -> Try(Str, Str)
	hop = |declared, current, location| {
		target = if location.starts_with("/") and !location.starts_with("//") {
			"${origin(current)}${location}"
		} else {
			location
		}
		if target.to_utf8().any(|b| b <= 32 or b >= 127) {
			return Err("a redirect to an address that is not plain text")
		}
		authority = origin(target).drop_prefix("https://").drop_prefix("http://")
		if authority.is_empty() or authority.contains("@") {
			return Err("a redirect to ${shown(target)}, which names no host or names credentials")
		}
		if target.starts_with("https://") or (loopback(declared) and loopback(target)) {
			Ok(target)
		} else {
			Err("a redirect to ${shown(target)}, which is not https")
		}
	}

	## `http://127.0.0.1`, with or without a port.
	loopback : Str -> Bool
	loopback = |url| url.starts_with("http://127.0.0.1:") or url.starts_with("http://127.0.0.1/")

	## The scheme and authority of a URL: what a path on the same host is
	## relative to.
	origin : Str -> Str
	origin = |url|
		match url.split_on("/") {
			[scheme, "", authority, ..] => "${scheme}//${authority}"
			_ => ""
		}

	## A URL as an error shows it: without its query, which may hold a
	## signature that is not ours to print.
	shown : Str -> Str
	shown = |url| url.split_on("?").first() ?? url

	## Whether asking again could help: the server was busy or failed.
	retryable : U16 -> Bool
	retryable = |status| status == 408 or status == 429 or status >= 500

	## The `Location` of a response, whatever the case of the header's name.
	location : List({ name : Str, value : Str }) -> Try(Str, [NoLocation])
	location = |headers|
		headers.find_first(|header| lowercase(header.name) == "location")
			.map_ok(|header| header.value.trim())
			.map_err(|_| NoLocation)
}

lowercase : Str -> Str
lowercase = |text| Str.from_utf8_lossy(text.to_utf8().map(|b| if (b >= 'A' and b <= 'Z') b + 32 else b))

## One URL, asked up to `Download.attempts` times: the body, and the address
## that served it after any redirect.
attempt! : Str, List((Str, Str)), U64 => Try({ bytes : List(U8), url : Str }, { status : U16, reason : Str })
attempt! = |url, headers, number|
	match follow!(url, url, headers, 0) {
		Ok(answer) => Ok(answer)
		Err(Final(status, reason)) => Err({ status, reason: "${reason} (${tried(number)})" })
		Err(Transient(status, reason)) =>
			if number >= Download.attempts {
				Err({ status, reason: "${reason} (${tried(number)})" })
			} else {
				Sleep.millis!(250 * number)
				attempt!(url, headers, number + 1)
			}
	}

tried : U64 -> Str
tried = |number| if (number == 1) "1 attempt" else "${number.to_str()} attempts"

## One request, and the redirects that follow it under `Download.hop`. The
## address that answers with a body is `current` then, and is returned with
## it.
follow! : Str, Str, List((Str, Str)), U64 => Try({ bytes : List(U8), url : Str }, [Final(U16, Str), Transient(U16, Str)])
follow! = |declared, current, headers, hops| {
	plain = Request.from_method(GET).with_uri(current).with_timeout(TimeoutMilliseconds(Download.timeout_ms))
	request = headers.fold(plain, |built, (name, value)| built.add_header(name, value))
	response = match Http.send!(request) {
		Ok(answer) => answer
		Err(HttpErr(Timeout)) => return Err(Transient(0, "no answer from ${Download.shown(current)} within ${(Download.timeout_ms // 1000).to_str()} seconds"))
		Err(HttpErr(_)) => return Err(Transient(0, "could not reach ${Download.shown(current)}"))
		Err(InvalidUrl(_)) => return Err(Final(0, "${Download.shown(current)} is not a URL"))
	}
	status = Response.status(response)
	if status >= 200 and status < 300 {
		Ok({ bytes: Response.body(response), url: current })
	} else if status >= 300 and status < 400 {
		if hops >= Download.max_hops {
			return Err(Final(status, "more than ${Download.max_hops.to_str()} redirects"))
		}
		target = match Download.location(Response.headers(response)) {
			Ok(value) => Download.hop(declared, current, value).map_err(|reason| Final(status, reason))?
			Err(NoLocation) => return Err(Final(status, "HTTP ${status.to_str()} from ${Download.shown(current)} with no Location"))
		}
		follow!(declared, target, [], hops + 1)
	} else if Download.retryable(status) {
		Err(Transient(status, "HTTP ${status.to_str()} from ${Download.shown(current)}"))
	} else {
		Err(Final(status, "HTTP ${status.to_str()} from ${Download.shown(current)}"))
	}
}

release : Str
release = "https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-04-130536d/roc.tar.gz"

# A release host redirects to a signed address on another host: the query
# stays, and the hop is HTTPS.
expect Download.hop(release, release, "https://release-assets.githubusercontent.com/asset/1?sig=abc&se=2026") == Ok("https://release-assets.githubusercontent.com/asset/1?sig=abc&se=2026")

# A path alone is on the host that sent it.
expect Download.hop(release, "https://example.test:8443/a/b", "/c/d?x=1") == Ok("https://example.test:8443/c/d?x=1")

# Nothing leaves HTTPS, to any host, loopback included.
expect
	["http://example.test/tool", "http://127.0.0.1:8080/tool", "ftp://example.test/tool", "file:///etc/passwd", "//example.test/tool", "tool", ""].all(
		|target| Download.hop(release, release, target).is_err(),
	)
expect Download.hop(release, release, "http://example.test/tool") == Err("a redirect to http://example.test/tool, which is not https")

# A download declared on the loopback address may be redirected there, and to
# HTTPS, and nowhere else in plain HTTP.
expect Download.hop("http://127.0.0.1:4000/a", "http://127.0.0.1:4000/a", "http://127.0.0.1:4000/b") == Ok("http://127.0.0.1:4000/b")
expect Download.hop("http://127.0.0.1:4000/a", "http://127.0.0.1:4000/a", "/b") == Ok("http://127.0.0.1:4000/b")
expect Download.hop("http://127.0.0.1:4000/a", "http://127.0.0.1:4000/a", "https://example.test/b") == Ok("https://example.test/b")
expect Download.hop("http://127.0.0.1:4000/a", "http://127.0.0.1:4000/a", "http://example.test/b").is_err()
expect Download.hop("http://127.0.0.1:4000/a", "http://127.0.0.1:4000/a", "http://127.0.0.1.example.test/b").is_err()

# A hop names no credentials and holds nothing but plain text; a signature in
# a refused address is not printed.
expect Download.hop(release, release, "https://user:secret@example.test/tool").is_err()
expect Download.hop(release, release, "https://example.test/a b").is_err()
expect Download.hop(release, release, "https:///tool").is_err()
expect Download.hop(release, release, "http://example.test/tool?sig=secret") == Err("a redirect to http://example.test/tool, which is not https")

expect Download.origin("https://example.test:8443/a/b?c=d") == "https://example.test:8443" and Download.origin("example.test/a") == ""
expect Download.shown("https://example.test/a?sig=1") == "https://example.test/a" and Download.shown("https://example.test/a") == "https://example.test/a"
expect Download.loopback("http://127.0.0.1:1/a") and Download.loopback("http://127.0.0.1/a") and !Download.loopback("https://127.0.0.1/a") and !Download.loopback("http://127.0.0.10/a")

# A busy or failing server is asked again; a refusal is not.
expect [408, 429, 500, 502, 503].all(Download.retryable) and ![400, 401, 403, 404, 410].any(Download.retryable)

expect Download.location([{ name: "Content-Length", value: "0" }, { name: "LOCATION", value: " https://example.test/b\r" }]) == Ok("https://example.test/b")
expect Download.location([{ name: "Content-Length", value: "0" }]) == Err(NoLocation)

expect tried(1) == "1 attempt" and tried(3) == "3 attempts"
