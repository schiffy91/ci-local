{
  description = "ci-local: a commit's local test passes stand in for the same jobs in CI";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      each = body: nixpkgs.lib.genAttrs systems (system: body nixpkgs.legacyPackages.${system});
    in {
      packages = each (pkgs: rec {
        ci-local = import ./package.nix { inherit pkgs; };
        default = ci-local;
      });
      # The tool against a repository of its own, and this repository's workflow against its own job table.
      # A repository that uses the tool builds the same check against its table and workflow:
      #   import "${inputs.ci-local}/tests/ci_local.nix" { inherit pkgs; table = ./ci/local.json; workflow = ./.github/workflows/checks.yml; jobs = [ "lint" "checks" ]; }
      checks = each (pkgs: { ci-local = import ./tests/ci_local.nix { inherit pkgs; }; });
    };
}
