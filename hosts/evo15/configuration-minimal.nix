{ pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./disko.nix
  ];

  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      trusted-users = [ "root" "jbellavista" ];
      auto-optimise-store = true;
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };
  };

  nixpkgs.config.allowUnfree = true;

  time.timeZone = "Europe/Madrid";
  i18n.defaultLocale = "en_US.UTF-8";

  console = {
    keyMap = "es";
    earlySetup = true;
  };

  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };
    initrd.systemd.enable = true;
    tmp.cleanOnBoot = true;
  };

  networking.hostName = "evo15";
  networking.networkmanager.enable = true;

  programs.zsh.enable = true;
  users.defaultUserShell = pkgs.zsh;

  security = {
    polkit.enable = true;
    sudo.wheelNeedsPassword = true;
  };

  services.openssh.enable = true;
  services.fstrim.enable = true;

  users.users.jbellavista.openssh.authorizedKeys.keys = [
    # personal desktop (pop-os) -> evo15; private half: ~/.ssh/id_ed25519_evo15
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMOEEzR/dAVHRKsrABpTl1UM+waJr2Whp6C7orZxrWaM pop-os->evo15"
  ];

  hardware.enableRedistributableFirmware = true;
  zramSwap.enable = true;

  environment.systemPackages = with pkgs; [
    btrfs-progs
    curl
    git
    htop
    nano
    pciutils
    usbutils
    vim
    wget
  ];

  users.mutableUsers = true;
  users.users.jbellavista = {
    isNormalUser = true;
    description = "Joan Bellavista";
    shell = pkgs.zsh;
    extraGroups = [
      "audio"
      "input"
      "networkmanager"
      "video"
      "wheel"
    ];
  };

  system.stateVersion = "25.11";
}
