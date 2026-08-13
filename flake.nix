{
  description = "Declarative NixOS config for the Slimbook EVO15";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-master.url = "github:NixOS/nixpkgs/master";

    disko = {
      url = "github:nix-community/disko/latest";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    lanzaboote = {
      url = "github:nix-community/lanzaboote";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    eve-protocol-observatory = {
      url = "path:./stubs/eve-protocol-observatory";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nvim-config = {
      url = "github:jbb494/nvim";
      flake = false;
    };

    rollnroll-devtools.url = "path:./stubs/rollnroll-devtools";
  };

  outputs = inputs@{ self, nixpkgs, disko, home-manager, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
      masterPkgs = import inputs.nixpkgs-master {
        inherit system;
        config.allowUnfree = true;
      };
      xkeyboardConfigErgodox = pkgs.callPackage ./packages/xkeyboard-config-ergodox.nix { };
      eveAvailable = inputs.eve-protocol-observatory.available or false;
      eveRuntimePackages = if eveAvailable then inputs.eve-protocol-observatory.ags.packages.${system} else [ ];
      eveShellModule = if eveAvailable then inputs.eve-protocol-observatory.ags.shellModule.${system} else null;
    in
    {
      nixosConfigurations.evo15 = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          inherit inputs self masterPkgs xkeyboardConfigErgodox;
        };
        modules = [
          disko.nixosModules.disko
          home-manager.nixosModules.home-manager
          ./hosts/evo15/configuration.nix
        ];
      };

      nixosConfigurations.evo15-bootstrap = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          inherit inputs self masterPkgs xkeyboardConfigErgodox;
        };
        modules = [
          disko.nixosModules.disko
          ./hosts/evo15/configuration-bootstrap.nix
        ];
      };

      nixosConfigurations.desktop = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          inherit inputs self masterPkgs xkeyboardConfigErgodox;
        };
        modules = [
          disko.nixosModules.disko
          home-manager.nixosModules.home-manager
          inputs.lanzaboote.nixosModules.lanzaboote
          ./hosts/desktop/configuration.nix
        ];
      };

      nixosConfigurations.desktop-bootstrap = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          inherit inputs self masterPkgs xkeyboardConfigErgodox;
        };
        modules = [
          disko.nixosModules.disko
          ./hosts/desktop/configuration-bootstrap.nix
        ];
      };

      packages.${system} = {
        inherit xkeyboardConfigErgodox;
        jbellavista-shell = pkgs.callPackage ./packages/jbellavista-shell.nix {
          rollnrollShellModule = inputs.rollnroll-devtools.shellModules.ags.rollnroll or null;
          inherit eveRuntimePackages eveShellModule;
        };
        opencode2 = pkgs.callPackage ./packages/opencode2.nix { };
        install-evo15 = pkgs.callPackage ./apps/install-evo15.nix {
          diskoPackage = disko.packages.${system}.disko;
          nixosInstallTools = pkgs.nixos-install-tools;
        };
        install-desktop = pkgs.callPackage ./apps/install-desktop.nix {
          diskoPackage = disko.packages.${system}.disko;
          nixosInstallTools = pkgs.nixos-install-tools;
        };
      };

      apps.${system} = {
        jbellavista-shell = {
          type = "app";
          program = "${self.packages.${system}.jbellavista-shell}/bin/jbellavista-shell";
          meta.description = "Experimental AGS shell replacement for Hyprpanel";
        };

        install-evo15 = {
          type = "app";
          program = "${self.packages.${system}.install-evo15}/bin/install-evo15";
          meta.description = "Guarded destructive installer for the Slimbook EVO15";
        };

        install-desktop = {
          type = "app";
          program = "${self.packages.${system}.install-desktop}/bin/install-desktop";
          meta.description = "Guarded destructive installer for the desktop";
        };
      };

      checks.${system}.xkb-ergodox = pkgs.callPackage ./packages/check-xkb-ergodox.nix {
        inherit xkeyboardConfigErgodox;
      };

      formatter.${system} = pkgs.nixpkgs-fmt;
    };
}
