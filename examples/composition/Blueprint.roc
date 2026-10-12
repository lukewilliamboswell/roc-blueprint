# Imported pure functions compose ordinary settings, without a plugin registry.
app [config] { pf: platform "../../blueprint-platform/main.roc" }

import ProjectTasks
import Releases

config = [
	Name("composed"),
	Systems(["x86_64-linux"]),
	Fetch("blueprint", Releases.blueprint("0.5.0")),
	Environment("base", [Tools(["git"])]),
	Environment("dev", [Extend("base"), Tools(["python3", "git"])]),
	Environment("release", [Extend("dev"), Programs(["blueprint"])]),
	Shell("default", [Use("dev")]),
].concat(ProjectTasks.settings("dev"))
