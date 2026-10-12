import pf.Config

## A recipe is an ordinary function as well: given a release, it says where
## that release's `blueprint` is downloaded from on a system, or that there is
## none for it. It downloads nothing; `Fetch` takes its answers as data.
Releases :: [].{
	blueprint : Str -> (Str -> Config.Download)
	blueprint = |version|
		|system|
			match system {
				"x86_64-linux" | "aarch64-linux" | "aarch64-darwin" => File("https://github.com/lukewilliamboswell/roc-blueprint/releases/download/${version}/blueprint-${system}")
				_ => Unavailable
			}
}
