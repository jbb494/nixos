{ config
, inputs
, masterPkgs
, pkgs
, ...
}:

let
  cliproxyKeys = "/var/lib/cliproxyapi-keys";
in
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

  # T3 Code (desktop app, `t3`, `t3-hub`): no telemetry.
  environment.sessionVariables.T3CODE_TELEMETRY_ENABLED = "false";

  # SSH by key only (Tailscale and sshd are already on via modules/system/base.nix).
  services.openssh.settings = {
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false;
  };

  # Second person on this laptop, same Linux user: `claude-joan1` runs Claude
  # Code with its own login, settings and history in ~/.claude-joan1.
  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "claude-joan1";
      text = ''
        export CLAUDE_CONFIG_DIR="$HOME/.claude-joan1"
        exec ${masterPkgs.claude-code}/bin/claude "$@"
      '';
    })

    # `claude-hub`: same ~/.claude (memory, MCP, settings) but talks to Anthropic
    # through the local CLIProxyAPI below instead of its own claude.ai login.
    (pkgs.writeShellApplication {
      name = "claude-hub";
      text = ''
        export ANTHROPIC_BASE_URL="http://127.0.0.1:${toString config.services.cliproxyapi.settings.server.port}"
        ANTHROPIC_AUTH_TOKEN="$(cat ${cliproxyKeys}/api-key)"
        export ANTHROPIC_AUTH_TOKEN
        # A custom base URL drops the cache to 5 minutes; subscriptions get 1 hour.
        export CLAUDE_CODE_PROMPT_CACHE_TTL="1h"
        exec ${masterPkgs.claude-code}/bin/claude "$@"
      '';
    })

    # T3 Code: GUI for coding agents. `t3-hub` starts it in the browser with the
    # same proxy settings, so the Claude Code sessions it spawns use CLIProxyAPI.
    # Telemetry is off: see environment.sessionVariables.T3CODE_TELEMETRY_ENABLED.
    pkgs.t3code
    (pkgs.writeShellApplication {
      name = "t3-hub";
      text = ''
        export ANTHROPIC_BASE_URL="http://127.0.0.1:${toString config.services.cliproxyapi.settings.server.port}"
        ANTHROPIC_AUTH_TOKEN="$(cat ${cliproxyKeys}/api-key)"
        export ANTHROPIC_AUTH_TOKEN
        export CLAUDE_CODE_PROMPT_CACHE_TTL="1h"
        export PATH="${masterPkgs.claude-code}/bin:$PATH"
        exec ${pkgs.t3code}/bin/t3 "$@"
      '';
    })
    config.services.cliproxyapi.package
  ];

  # CLIProxyAPI: holds the Claude subscription login and serves it as an API on
  # localhost only. Logins live in /var/lib/cliproxyapi; add one with
  # `sudo -u cliproxyapi cliproxyapi -config /var/lib/cliproxyapi/config.yaml -claude-login`.
  services.cliproxyapi = {
    enable = true;
    settings = {
      config-version = 8;
      server = {
        host = "127.0.0.1";
        port = 8317;
        trusted-proxies = [ "127.0.0.1" "::1" ];
      };
      management.secret-key._secret = "${cliproxyKeys}/management-key";
      access.api-keys = [ { _secret = "${cliproxyKeys}/api-key"; } ];
      routing = {
        strategy = "round-robin";
        # Keep a conversation on one account so its prompt cache is reused.
        session-affinity = true;
        session-affinity-ttl = "1h";
        retry = {
          request-retry = 3;
          max-retry-interval = 30;
        };
      };
    };
  };

  # Random access + management keys, made once and kept out of Git. Readable by
  # jbellavista (for claude-hub); the service reads them as root via LoadCredential.
  systemd.services.cliproxyapi-keys = {
    description = "Generate CLIProxyAPI keys";
    wantedBy = [ "cliproxyapi.service" ];
    before = [ "cliproxyapi.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      install -d -m 0700 -o jbellavista -g users ${cliproxyKeys}
      for f in api-key management-key; do
        if [ ! -s ${cliproxyKeys}/$f ]; then
          (umask 0377; ${pkgs.openssl}/bin/openssl rand -hex 32 > ${cliproxyKeys}/$f)
          chown jbellavista:users ${cliproxyKeys}/$f
        fi
      done
    '';
  };

  # Passwords are set interactively by the installer; keep secrets out of Git.
  users.mutableUsers = true;
  users.users.jbellavista = {
    isNormalUser = true;
    # TEMPORARY: the agents VM's key for the platform migration; remove when done.
    # from= limits it to Tailscale addresses.
    openssh.authorizedKeys.keys = [
      ''from="100.64.0.0/10,fd7a:115c:a1e0::/48" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINH5NTBPuP+lb7O3ZJE3YO2VE1VT5qTAGTjSAZ7EMu/F platform@agents-vm (migration)''
    ];
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
