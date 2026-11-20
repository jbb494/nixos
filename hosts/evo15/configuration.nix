{ config
, inputs
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
    ../../modules/system/laptop.nix
    ../../modules/desktop/hyprland.nix
    ../../modules/keyboard/ergodox-dvorak.nix
  ];

  networking.hostName = "evo15";

  boot = {
    # Default LTS kernel series (deliberately not linuxPackages_latest).
    kernelPackages = pkgs.linuxPackages;
    kernelParams = [ "amd_pstate=active" ];

    # "Clean Cam": virtual webcam fed by the clean-cam user service (lighting fix).
    # exclusive_caps=1 is required for Chromium/Electron apps (Discord) to list it.
    extraModulePackages = [ config.boot.kernelPackages.v4l2loopback ];
    kernelModules = [ "v4l2loopback" ];
    extraModprobeConfig = ''
      options v4l2loopback devices=1 video_nr=10 card_label="Clean Cam" exclusive_caps=1
    '';
  };

  hardware.cpu.amd.updateMicrocode = true;

  # The FHD WebCam's controls are set by clean-cam when it opens the camera
  # (neutral, highlight-friendly values); no udev override any more.

  services.xserver.videoDrivers = [ "amdgpu" ];

  # Passwords are set interactively by the installer; keep secrets out of Git.
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

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    extraSpecialArgs = {
      inherit inputs masterPkgs;
      chromeForceEgl = false;
      opencodeLinearMcp = true;
      opencodePersonalProfile = true;
    };
    users.jbellavista = import ../../home/jbellavista/home.nix;
  };

  system.stateVersion = "25.11";
}
