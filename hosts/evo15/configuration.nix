{ inputs
, pkgs
, ...
}:

{
  imports = [
    ./hardware-configuration.nix
    ./disko.nix
    ../../modules/system/base.nix
    ../../modules/system/laptop.nix
    ../../modules/desktop/hyprland.nix
    ../../modules/keyboard/ergodox-dvorak.nix
  ];

  networking.hostName = "evo15";

  users.users.root.initialPassword = "nixos";
  users.users.jbellavista = {
    isNormalUser = true;
    description = "Joan Bellavista";
    shell = pkgs.zsh;
    initialPassword = "nixos";
    extraGroups = [
      "audio"
      "docker"
      "input"
      "networkmanager"
      "video"
      "wheel"
    ];
  };

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    extraSpecialArgs = { inherit inputs; };
    users.jbellavista = import ../../home/jbellavista/home.nix;
  };

  system.stateVersion = "25.11";
}
