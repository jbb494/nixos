{ inputs
, kernelPkgs
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
    kernelPackages = kernelPkgs.linuxPackages;
    kernelParams = [ "amd_pstate=active" ];
  };

  hardware.cpu.amd.updateMicrocode = true;

  services.udev.extraRules = ''
    ACTION=="add|change", SUBSYSTEM=="video4linux", ATTR{name}=="FHD WebCam: FHD WebCam", ATTR{index}=="0", ATTRS{idVendor}=="2b7e", ATTRS{idProduct}=="c906", RUN+="${pkgs.v4l-utils}/bin/v4l2-ctl --device=%N --set-ctrl=brightness=7,contrast=54,gamma=325,gain=82,sharpness=52,backlight_compensation=2"
  '';

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
      opencodeLinearMcp = true;
      opencodePersonalProfile = true;
    };
    users.jbellavista = import ../../home/jbellavista/home.nix;
  };

  system.stateVersion = "25.11";
}
