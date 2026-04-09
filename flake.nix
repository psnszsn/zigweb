{
  description = "zigweb development shell";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-23.05";
    zig.url = "github:mitchellh/zig-overlay";
  };

  outputs = { nixpkgs, zig, ... }: let
    systems = [
      "aarch64-darwin"
      "aarch64-linux"
      "x86_64-linux"
    ];
  in {
    devShells = builtins.listToAttrs (map (system: {
      name = system;
      value = let
        pkgs = import nixpkgs { inherit system; };
      in {
        default = pkgs.mkShell {
          nativeBuildInputs = [
            zig.packages.${system}.master
          ];
        };
      };
    }) systems);
  };
}
