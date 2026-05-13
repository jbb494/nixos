{
  description = "Declarative NixOS config for the Slimbook EVO15";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    disko = {
      url = "github:nix-community/disko/latest";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nvim-config = {
      url = "github:jbb494/nvim";
      flake = false;
    };

    rollnroll-devtools.url = "git+ssh://git@github.com-rollnroll/joan-lgtm/devtools.git";
  };

  outputs = inputs@{ self, nixpkgs, disko, home-manager, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
      xkeyboardConfigErgodox = pkgs.callPackage ./packages/xkeyboard-config-ergodox.nix { };
    in
    {
      nixosConfigurations.evo15 = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          inherit inputs self xkeyboardConfigErgodox;
        };
        modules = [
          disko.nixosModules.disko
          home-manager.nixosModules.home-manager
          ./hosts/evo15/configuration.nix
        ];
      };

      nixosConfigurations.evo15-minimal = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          inherit inputs self xkeyboardConfigErgodox;
        };
        modules = [
          disko.nixosModules.disko
          ./hosts/evo15/configuration-minimal.nix
        ];
      };

      packages.${system} = {
        inherit xkeyboardConfigErgodox;
        install-evo15 = pkgs.callPackage ./apps/install-evo15.nix {
          diskoPackage = disko.packages.${system}.disko;
          nixosInstallTools = pkgs.nixos-install-tools;
        };
      };

      apps.${system}.install-evo15 = {
        type = "app";
        program = "${self.packages.${system}.install-evo15}/bin/install-evo15";
        meta.description = "Guarded destructive installer for the Slimbook EVO15";
      };

      checks.${system}.xkb-ergodox = pkgs.callPackage ./packages/check-xkb-ergodox.nix {
        inherit xkeyboardConfigErgodox;
      };

      formatter.${system} = pkgs.nixpkgs-fmt;
    };
}
