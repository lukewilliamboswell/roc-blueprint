import pf.Config
import pf.System

## A recipe is an ordinary function as well: given a release, it says where
## that release's `blueprint` is downloaded from on a system, or that there is
## none for it. It downloads nothing; `Fetch` takes its answers as data. Its
## type is written out, so that a mistake in it is reported on its own line.
Releases :: [].{
	blueprint : Str -> (System -> Config.Download)
	blueprint = |version|
		|system|
			match system {
				"x86_64-linux" | "aarch64-linux" | "aarch64-darwin" => File("https://github.com/lukewilliamboswell/roc-blueprint/releases/download/${version}/blueprint-${system.to_str()}")
				_ => Unavailable
			}
}
