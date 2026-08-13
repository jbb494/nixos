{
  description = "Unavailable local EVE protocol observatory stub";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }: {
    available = false;

    nixosModules.default = { ... }: { };

    ags = {
      packages.x86_64-linux = [ ];
      shellModule.x86_64-linux = null;
    };
  };
}
