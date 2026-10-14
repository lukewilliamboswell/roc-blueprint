import cli.Duration
import cli.Cmd
import cli.Tcp
import Process
import Script

## A localhost HTTP server for files held in memory, on a port the operating
## system assigns. It has no thread of its own: it answers requests in short
## polls while the caller waits for the child processes that make them.
Serve := { listener : Tcp.Listener, port : U16, routes : List(Route) }.{

	## A request path without its leading `/`, and what is served there: the
	## bytes with `200 OK`, or another status, with a `Location` when it has
	## one to give.
	Route : { path : Str, bytes : List(U8), status : Str, location : Str }

	## Listen on 127.0.0.1 with nothing to serve yet.
	open! : () => Try(Serve, _)
	open! = || {
		listener = Tcp.listen!("127.0.0.1", 0, Duration.millis(io_timeout_ms))?
		port = listener.local_port!()?
		Ok(Serve.{ listener, port, routes: [] })
	}

	## The same server, also serving `bytes` at `path`.
	with_route : Serve, Str, List(U8) -> Serve
	with_route = |self, path, bytes| Serve.{ listener: self.listener, port: self.port, routes: self.routes.append({ path, bytes, status: "200 OK", location: "" }) }

	## The same server, also redirecting `path` to `location`.
	with_redirect : Serve, Str, Str -> Serve
	with_redirect = |self, path, location| Serve.{ listener: self.listener, port: self.port, routes: self.routes.append({ path, bytes: [], status: "302 Found", location }) }

	## The same server, also answering `path` with `status` and no body.
	with_status : Serve, Str, Str -> Serve
	with_status = |self, path, status| Serve.{ listener: self.listener, port: self.port, routes: self.routes.append({ path, bytes: [], status, location: "" }) }

	## The same server with nothing to serve: every request is refused.
	emptied : Serve -> Serve
	emptied = |self| Serve.{ listener: self.listener, port: self.port, routes: [] }

	url : Serve, Str -> Str
	url = |self, path| "http://127.0.0.1:${self.port.to_str()}/${path}"

	## Start every command, then answer requests until each has exited. The
	## outcomes come back in the order given.
	drive! : Serve, List(Process.Job) => Try(List(Process.Outcome), _)
	drive! = |self, jobs| until_exit!(self, Process.spawn_each!(jobs, [])?, [])

	## Answer requests until every child has exited.
	until_exit! : Serve, List(Cmd.Child), List(Process.Outcome) => Try(List(Process.Outcome), _)
	until_exit! = |self, children, finished|
		match children {
			[] => Ok(finished)
			[first, .. as rest] =>
				match first.poll!() {
					Ok(Running) => {
						answer_one!(self)?
						until_exit!(self, children, finished)
					}
					Ok(Finished(output)) => until_exit!(self, rest, finished.append(Process.outcome(output)))
					Err(_) => Script.fail!("could not wait for a child process")
				}
		}

	## Stop listening.
	shut! : Serve => Try({}, _)
	shut! = |self| Tcp.Listener.close!(self.listener)

	## The path a request line asks for, without its leading `/`.
	requested : Str -> Try(Str, [BadRequest])
	requested = |line|
		match line.trim().split_on(" ") {
			["GET", target, ..] => if target.starts_with("/") Ok(target.drop_prefix("/")) else Err(BadRequest)
			_ => Err(BadRequest)
		}

	## The status line and headers of a response with `length` body bytes.
	## HTTP separates lines with CRLF.
	head : Str, U64 -> Str
	head = |status, length| headed(status, length, "")

	## `head`, with a `Location` when there is one.
	headed : Str, U64, Str -> Str
	headed = |status, length, location|
		Str.join_with(
			[
				"HTTP/1.1 ${status}",
				"Content-Type: application/octet-stream",
				"Content-Length: ${length.to_str()}",
			]
				.concat(if location.is_empty() [] else ["Location: ${location}"])
				.concat(["Connection: close", "", ""]),
			"\r\n",
		)
}

## How long one poll waits for a connection before the caller looks at its
## child again.
accept_timeout_ms = 100

io_timeout_ms = 5_000

body_timeout_ms = 30_000

max_line_bytes = 65_536

max_header_lines = 100

## Wait briefly for one connection and answer it; return if none arrives.
answer_one! : Serve => Try({}, _)
answer_one! = |server|
	match server.listener.accept!({ accept_timeout: After(Duration.millis(accept_timeout_ms)), io_timeout: Duration.millis(io_timeout_ms) }) {
		Ok(stream) => {
			line = stream.with_line_limit(max_line_bytes).read_line!() ?? ""
			skip_headers!(stream, max_header_lines)
			found = match Serve.requested(line) {
				Ok(path) => server.routes.find_first(|route| route.path == path).map_err(|_| NotServed)
				Err(BadRequest) => Err(NotServed)
			}
			# A client that goes away mid-response is its own failure to report.
			_ = respond!(stream, found)
			Ok({})
		}
		Err(TcpErr(TimedOut)) => Ok({})
		Err(_) => Script.fail!("the bundle server could not accept a connection")
	}

respond! : Tcp.Connection, Try(Serve.Route, [NotServed]) => Try({}, _)
respond! = |stream, found|
	match found {
		Ok(route) => {
			stream.write_utf8!(Serve.headed(route.status, route.bytes.len(), route.location))?
			stream.with_timeout(Duration.millis(body_timeout_ms)).write_bytes!(route.bytes)
		}
		Err(NotServed) => stream.write_utf8!(Serve.head("404 Not Found", 0))
	}

## Read the request's remaining header lines, so the response is not written
## to a client that is still sending.
skip_headers! : Tcp.Connection, U64 => {}
skip_headers! = |stream, remaining|
	if remaining > 0 {
		match stream.with_line_limit(max_line_bytes).read_line!() {
			Ok(line) => if line.trim().is_empty() {} else skip_headers!(stream, remaining - 1)
			Err(_) => {}
		}
	}

expect Serve.requested("GET /0.0.1-smoke/abc.tar.zst HTTP/1.1\r\n") == Ok("0.0.1-smoke/abc.tar.zst")
expect Serve.requested("GET / HTTP/1.1\r\n") == Ok("")
expect Serve.requested("POST /abc HTTP/1.1\r\n") == Err(BadRequest)
expect Serve.requested("GET abc HTTP/1.1\r\n") == Err(BadRequest)
expect Serve.requested("") == Err(BadRequest)
expect Serve.head("200 OK", 12) == "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 12\r\nConnection: close\r\n\r\n"
expect Serve.headed("302 Found", 0, "http://127.0.0.1:1/b") == "HTTP/1.1 302 Found\r\nContent-Type: application/octet-stream\r\nContent-Length: 0\r\nLocation: http://127.0.0.1:1/b\r\nConnection: close\r\n\r\n"
