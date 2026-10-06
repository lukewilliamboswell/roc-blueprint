import cli.Cmd
import cli.Tcp
import Process
import Script

## A localhost HTTP server for files held in memory, on a port the operating
## system assigns. It has no thread of its own: it answers requests in short
## polls while the caller waits for the child processes that make them.
Serve := { listener : Tcp.Listener, port : U16, routes : List(Route) }.{

	## A request path without its leading `/`, and the bytes served there.
	Route : { path : Str, bytes : List(U8) }

	## Listen on 127.0.0.1 with nothing to serve yet.
	open! : () => Try(Serve, _)
	open! = || {
		listener = Tcp.listen!("127.0.0.1", 0, io_timeout_ms)?
		port = listener.local_port!()?
		Ok(Serve.{ listener, port, routes: [] })
	}

	## The same server, also serving `bytes` at `path`.
	with_route : Serve, Str, List(U8) -> Serve
	with_route = |self, path, bytes| Serve.{ listener: self.listener, port: self.port, routes: self.routes.append({ path, bytes }) }

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
				match first.try_wait!() {
					Ok([]) => {
						answer_one!(self)?
						until_exit!(self, children, finished)
					}
					Ok([output, ..]) => until_exit!(self, rest, finished.append(Process.outcome(output)))
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
	head = |status, length|
		Str.join_with(
			[
				"HTTP/1.1 ${status}",
				"Content-Type: application/octet-stream",
				"Content-Length: ${length.to_str()}",
				"Connection: close",
				"",
				"",
			],
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
	match server.listener.accept!(accept_timeout_ms) {
		Ok(stream) => {
			line = stream.read_line!(max_line_bytes, io_timeout_ms) ?? ""
			skip_headers!(stream, max_header_lines)
			found = match Serve.requested(line) {
				Ok(path) => server.routes.find_first(|route| route.path == path).map_err(|_| NotServed)
				Err(BadRequest) => Err(NotServed)
			}
			# A client that goes away mid-response is its own failure to report.
			_ = respond!(stream, found)
			Ok({})
		}
		Err(TcpListenErr(TimedOut)) => Ok({})
		Err(_) => Script.fail!("the bundle server could not accept a connection")
	}

respond! : Tcp.Stream, Try(Serve.Route, [NotServed]) => Try({}, _)
respond! = |stream, found|
	match found {
		Ok(route) => {
			stream.write_utf8!(Serve.head("200 OK", route.bytes.len()), io_timeout_ms)?
			stream.write!(route.bytes, body_timeout_ms)
		}
		Err(NotServed) => stream.write_utf8!(Serve.head("404 Not Found", 0), io_timeout_ms)
	}

## Read the request's remaining header lines, so the response is not written
## to a client that is still sending.
skip_headers! : Tcp.Stream, U64 => {}
skip_headers! = |stream, remaining|
	if remaining > 0 {
		match stream.read_line!(max_line_bytes, io_timeout_ms) {
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
