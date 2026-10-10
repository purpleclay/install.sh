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
              files = "^(install\\.sh|test/.*\\.bats|test/stubs/.*)$";
            };

            shfmt = {
              enable = true;
              files = "^(install\\.sh|test/.*\\.bats|test/stubs/.*)$";
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

        # Only the busybox binary. The full package also links its applets
        # (ls, awk, tar and so on), which would shadow the real tools on PATH.
        busybox-sh = pkgs.runCommand "busybox-sh" {} ''
          mkdir -p $out/bin
          ln -s ${pkgs.busybox}/bin/busybox $out/bin/busybox
        '';
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
            buildInputs =
              [
                bats
                dash
                shfmt
                shellcheck
              ]
              # nixpkgs only builds busybox for Linux
              ++ lib.optionals stdenv.hostPlatform.isLinux [busybox-sh];
          };
        }
    );
}
