{ pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./disko.nix
    ../../modules/system/base.nix
    ../../modules/system/laptop.nix
  ];

  networking.hostName = "evo15";

  services.openssh.enable = true;

  users.mutableUsers = true;
  users.users.jbellavista = {
    isNormalUser = true;
    description = "Joan Bellavista";
    shell = pkgs.zsh;
    extraGroups = [
      "audio"
      "docker"
      "input"
      "networkmanager"
      "video"
      "wheel"
    ];
  };

  system.stateVersion = "25.11";
}
