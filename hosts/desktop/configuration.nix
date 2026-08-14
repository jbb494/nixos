{ config
, inputs
, lib
, masterPkgs
, pkgs
, ...
}:

{
  imports = [
    ./hardware-configuration.nix
    ./disko.nix
    ../../modules/system/base.nix
    ../../modules/system/workstation.nix
    ../../modules/desktop/hyprland.nix
    ../../modules/keyboard/ergodox-dvorak.nix
    inputs.eve-protocol-observatory.nixosModules.default
  ];

  networking.hostName = "desktop";

  console.keyMap = pkgs.lib.mkForce "dvorak";

  boot = {
    loader.systemd-boot.enable = true;
  };

  hardware = {
    cpu.amd.updateMicrocode = true;
    nvidia = {
      modesetting.enable = true;
      nvidiaSettings = true;
      open = true;
      package = config.boot.kernelPackages.nvidiaPackages.stable;
    };
  };

  services = {
    xserver.videoDrivers = [ "nvidia" ];
  } // lib.optionalAttrs (inputs.eve-protocol-observatory.available or false) {
    eve-protocol-observatory = {
      enable = true;
      user = "jbellavista";
    };
  };

  environment.sessionVariables = {
    GBM_BACKEND = "nvidia-drm";
    LIBVA_DRIVER_NAME = "nvidia";
    __GLX_VENDOR_LIBRARY_NAME = "nvidia";
  };

  programs.wireshark.enable = true;

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
      "wireshark"
    ];
  };

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    extraSpecialArgs = {
      inherit inputs masterPkgs;
      opencodeLinearMcp = false;
      opencodePersonalProfile = false;
    };
    users.jbellavista = import ../../home/jbellavista/home.nix;
  };

  system.stateVersion = "25.11";
}
