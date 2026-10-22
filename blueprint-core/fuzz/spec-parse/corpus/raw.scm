((format ((major 3) (minor 0))) (name "r") (requires ("raw")) (inputs (( (name "fu") (url "github:numtide/flake-utils")))) (raw (((backend "nix") (target "flake") (value (Str "{ }"))) ((backend "other") (target "") (value (Bool false)))))
 (resolvers (((provider "nix") (inputs ("fu"))))))
