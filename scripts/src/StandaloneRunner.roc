import cli.Cmd
import cli.Env
import cli.OsStr
import cli.Path
import nix.Locks
import BuildHarness
import Process
import Script

## Exact production-native runner mechanics under private test namespaces.
## Production isolation itself is always checked by real Nix build gates.
StandaloneRunner := [].{
	Witness : [Observed, Missing, Provided(Str), Shared]
	Outcome : { code : I32, stdout : Str, stderr : Str, top : Str }

	locate! : Str, Str => Try(Str, _)
	locate! = |generated, name| Cmd.new("nix").args(["eval", "--raw", "--impure", "--offline", "${Locks.path_reference(generated)}#packages.x86_64-linux.${name}.builder"].map(OsStr.from_str)).capture!().map_ok(Str.trim)

	bridge! : { root : Str, work : Str } => Try(Str, _)
	bridge! = |context| {
		program = "${context.work}/witness-bridge"
		if !(Path.is_file!(Path.utf8(program)) ?? False) {
			Cmd.new(OsStr.from_str(Process.roc!())).args(["build", "${context.root}/fixtures/builds/witness_bridge.roc", "--output=${program}"].map(OsStr.from_str)).exec!()?
		}
		Ok(program)
	}

	payload! : { root : Str, work : Str } => Try(Str, _)
	payload! = |context| {
		program = "${context.work}/runner-payload"
		if !(Path.is_file!(Path.utf8(program)) ?? False) {
			Cmd.new(OsStr.from_str(Process.roc!())).args(["build", "${context.root}/fixtures/builds/runner_payload.roc", "--output=${program}"].map(OsStr.from_str)).exec!()?
		}
		Ok(program)
	}

	run! : { root : Str, work : Str }, Str, Witness => Try(Outcome, _)
	run! = |context, specification, witness| {
		top = Path.to_str(Env.create_temp_dir_in!(Path.utf8(context.work), "standalone-")?)?
		build = "${top}/build"
		Path.create_dir!(Path.utf8(build))?
		Path.create_dir!(Path.utf8("${top}/witness"))?
		Path.write_utf8!(Path.utf8("${top}/spec.json"), specification)?
		observed! = |name| Cmd.new("readlink").arg(OsStr.from_str("/proc/self/ns/${name}")).capture!().map_ok(Str.trim)
		contents = match witness {
			Provided(text) => text
			_ => "${observed!("mnt")?}\n${observed!("net")?}\n"
		}
		if witness != Missing {
			Path.write_utf8!(Path.utf8("${top}/witness/witness"), contents)?
		}
		bwrap = BuildHarness.which!("bwrap")?
		readlink = BuildHarness.which!("readlink")?
		require = |tool| tool.starts_with("/nix/store/")
		if ![bwrap, readlink].all(require) {
			return Script.fail!("runner tests require pinned Nix bubblewrap and coreutils")
		}
		runner = Path.read_utf8!(Path.utf8("${context.work}/standalone-runner-path"))?.trim()
		if !runner.starts_with("/nix/store/") {
			return Script.fail!("runner tests must use the actual Nix-built production builder")
		}
		argv = if witness == Shared {
			bridge = bridge!(context)?
			[bridge, "${top}/witness/witness", runner]
		} else {
			[runner]
		}
		uid = Cmd.new("id").arg("-u").capture!()?.trim()
		gid = Cmd.new("id").arg("-g").capture!()?.trim()
		setpriv = BuildHarness.which!("setpriv")?
		unprivileged = [setpriv, "--reuid=${uid}", "--regid=${gid}", "--clear-groups"].concat(argv)
		# Create witness mountpoints inside private tmpfs, never the host root.
		# The suite's own writable directory is rebound after hiding /tmp.
		result = Cmd.new("sudo").args(["-n", "--", bwrap, "--die-with-parent", "--unshare-net", "--ro-bind", "/", "/", "--tmpfs", "/tmp", "--bind", context.work, context.work, "--tmpfs", "/tmp/roc-build-runner-isolation", "--ro-bind", "${top}/witness", "/tmp/roc-build-runner-isolation", "--chdir", build, "--clearenv", "--setenv", "ROC_BUILD_RUNNER_WITNESS", "/tmp/roc-build-runner-isolation/witness", "--setenv", "ROC_BUILD_RUNNER_READLINK", readlink, "--setenv", "runnerSpecPath", "${top}/spec.json", "--setenv", "out", "${top}/out", "--"].concat(unprivileged).map(OsStr.from_str)).run!()?
		code = match result.status {
			Exited(value) => value
			Signaled(signal) => 128 + signal
		}
		Ok({ code, stdout: Str.from_utf8_lossy(result.stdout_bytes), stderr: Str.from_utf8_lossy(result.stderr_bytes), top })
	}
}
