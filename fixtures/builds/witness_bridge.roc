# Negative control: forge a witness naming this test namespace, then run the
# unmodified production builder. The builder must refuse before effects.
app [main!] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc2/Gj3zVDr3qrQa6aTh7Z1zgUfe9NeBE6R76T5ho3xrc8af.tar.zst" }

import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path

main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	result! = || {
		selected = match args {
			[file, program] => { witness: file, runner: program }
			_ => return Err(BadArguments)
		}
		readlink = Env.var!("ROC_BUILD_RUNNER_READLINK")?
		mnt = Cmd.new(readlink).arg("/proc/self/ns/mnt").capture!()?.trim()
		net = Cmd.new(readlink).arg("/proc/self/ns/net").capture!()?.trim()
		Path.from_os_str(selected.witness).write_utf8!("${mnt}\n${net}\n")?
		Cmd.new(selected.runner).exec!()
	}
	match result!() {
		Ok({}) => Ok({})
		_ => Err(Exit(1))
	}
}
