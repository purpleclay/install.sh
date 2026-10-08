{
  description = "One script to install them all";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };
  };

  outputs = {
    nixpkgs,
    flake-utils,
    git-hooks,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = import nixpkgs {
          inherit system;
        };

        pre-commit-check = git-hooks.lib.${system}.run {
          src = ./.;
          package = pkgs.prek;
          hooks = {
            alejandra = {
              enable = true;
              files = "^flake\\.nix$";
              settings = {
                check = true;
              };
            };

            shellcheck = {
              enable = true;
              files = "^(install\\.sh|test/.*\\.bats)$";
            };

            shfmt = {
              enable = true;
              files = "^(install\\.sh|test/.*\\.bats)$";
              args = ["-i" "2" "-ci"];
            };

            typos = {
              enable = true;
            };

            zizmor = {
              enable = true;
              files = "^\\.github/workflows/.*\\.ya?ml$";
            };
          };
        };

        bats = pkgs.bats.withLibraries (p: [
          p.bats-assert
          p.bats-support
        ]);
      in
        with pkgs; {
          devShells.default = mkShell {
            inherit (pre-commit-check) shellHook;

            buildInputs =
              [
                alejandra
                bats
                nil
                shfmt
                shellcheck
                typos
                zizmor
              ]
              ++ pre-commit-check.enabledPackages;
          };

          devShells.ci = mkShell {
            buildInputs = [
              bats
              shfmt
              shellcheck
            ];
          };
        }
    );
}
