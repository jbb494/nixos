{ pkgs, ... }:

{
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

  networking.networkmanager.enable = true;

  programs = {
    zsh.enable = true;
    nix-ld.enable = true;
  };

  users.defaultUserShell = pkgs.zsh;

  security = {
    polkit.enable = true;
    rtkit.enable = true;
    sudo.wheelNeedsPassword = true;
  };

  services = {
    dbus.enable = true;
    fstrim.enable = true;
    gvfs.enable = true;
    openssh.enable = true;
    pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      jack.enable = true;
      pulse.enable = true;
    };
  };

  users.users.jbellavista.openssh.authorizedKeys.keys = [
    # personal desktop (pop-os) -> evo15; private half: ~/.ssh/id_ed25519_evo15
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMOEEzR/dAVHRKsrABpTl1UM+waJr2Whp6C7orZxrWaM pop-os->evo15"
  ];

  virtualisation.docker.enable = true;
  zramSwap.enable = true;

  environment.systemPackages = with pkgs; [
    btrfs-progs
    curl
    fd
    file
    git
    htop
    jq
    killall
    nano
    neovim
    pciutils
    ripgrep
    tldr
    tree
    unzip
    usbutils
    vim
    wget
    zip
  ];

  fonts.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-color-emoji
  ];
}
