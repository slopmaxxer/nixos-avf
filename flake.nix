{
  description = "NixOS for Android Terminal (Android Virtualization Framework)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs =
    { self, nixpkgs, ... }:
    let
      inherit (nixpkgs) lib;
      forAllSystems = lib.genAttrs lib.systems.flakeExposed;
    in
    {
      nixosModules = {
        avf = import ./avf;
        avfDebug = import ./avf/debug.nix;
        avfInitial = import ./initial;
      };

      packages = forAllSystems (system: let
        nixos = lib.nixosSystem {
          inherit system;
          modules = with self.nixosModules; [
            avf
            avfInitial
            avfDebug
          ];
        };
        android17 = lib.nixosSystem {
          inherit system;
          modules = [
            self.nixosModules.avf
            {
              avf.terminal = 17;
              system.stateVersion = lib.trivial.release;
            }
          ];
        };
      in {
        initialImage = nixos.config.system.build.avfImage;
        # What initial/install-in-place.sh installs on an Android 17 Terminal
        android17System = android17.config.system.build.toplevel;
      });

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-tree);
    };
}
