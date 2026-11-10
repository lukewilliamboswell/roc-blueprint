import pf.System

## Adapt native target discovery to the portable host names used by plans.
Platform := [].{
	current! : () => { arch : [X64, AARCH64], os : [LINUX, MACOS, WINDOWS] }
	current! = || {
		target = System.target!()
		arch = match target.arch() {
			X64 => X64
			Arm64 => AARCH64
		}
		os = match target.os() {
			Linux(_) => LINUX
			MacOS(_) => MACOS
			Windows(_) => WINDOWS
		}
		{ arch, os }
	}
}
