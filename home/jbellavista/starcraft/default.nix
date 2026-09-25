{ lib, osConfig, pkgs, ... }:

let
  starcraftGamescope = pkgs.writeShellApplication {
    name = "starcraft-gamescope";
    runtimeInputs = [ pkgs.gamescope ];
    text = ''
      # Steam's FHS namespace omits /etc/egl, where NVIDIA normally discovers
      # its external EGL platform modules. The same modules are exposed here.
      export __EGL_EXTERNAL_PLATFORM_CONFIG_DIRS=/run/opengl-driver/share/egl/egl_external_platform.d

      exec gamescope \
        --output-width 2560 \
        --output-height 1440 \
        --nested-width 2560 \
        --nested-height 1440 \
        --borderless \
        -- env -u __EGL_EXTERNAL_PLATFORM_CONFIG_DIRS "$@"
    '';
  };
  battleNetInstaller = pkgs.fetchurl {
    name = "Battle.net-Setup.exe";
    url = "https://downloader.battle.net/download/installer/win/1.0.66/Battle.net-Setup.exe";
    hash = "sha256-3l0y1Ope7VqeEgAn+2izcJdtv+zI8qj5EwWXfwuH/K8=";
  };
  syncStarcraftSteamShortcut = pkgs.writeShellApplication {
    name = "sync-starcraft-steam-shortcut";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.procps
      (pkgs.python3.withPackages (pythonPackages: [ pythonPackages.vdf ]))
    ];
    text = ''
      export BATTLE_NET_INSTALLER=${lib.escapeShellArg battleNetInstaller}

      sync_once() {
        python ${./steam-sync.py}
      }

      # Steam keeps shortcuts.vdf and config.vdf in memory and rewrites them
      # on exit. Synchronize only while it is stopped, then wait for the next
      # complete Steam run before checking whether installation changed the
      # prefix and the shortcut should switch between installer and launcher.
      while true; do
        while pgrep -x steam >/dev/null; do
          sleep 1
        done
        sleep 1
        sync_once
        while ! pgrep -x steam >/dev/null; do
          sleep 1
        done
      done
    '';
  };
  starcraftSteamGameId = "13439389832463777792";
in
lib.mkIf (osConfig.networking.hostName == "desktop") {
  home.packages = [ starcraftGamescope ];

  # Steam's sandbox can access the home directory, but not the per-user
  # profile under /etc. Keep a stable launcher path across HM generations.
  home.file.".local/bin/starcraft-gamescope".source =
    "${starcraftGamescope}/bin/starcraft-gamescope";

  xdg.dataFile."applications/starcraft-ii.desktop".text = ''
    [Desktop Entry]
    Version=1.0
    Type=Application
    Name=StarCraft II
    GenericName=Real-time Strategy Game
    Comment=Launch StarCraft II through Steam and Battle.net
    Exec=${pkgs.steam}/bin/steam steam://rungameid/${starcraftSteamGameId}
    Icon=steam
    Terminal=false
    StartupNotify=false
    Categories=Game;StrategyGame;
    Keywords=StarCraft;SC2;Battle.net;Blizzard;Protoss;
  '';

  systemd.user.services.sync-starcraft-steam-shortcut = {
    Unit = {
      Description = "Declaratively configure the StarCraft II Steam shortcut";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      Type = "simple";
      ExecStart = "${syncStarcraftSteamShortcut}/bin/sync-starcraft-steam-shortcut";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  wayland.windowManager.hyprland = {
    settings = {
      config.master = {
        always_keep_position = true;
        mfact = 0.7441860465;
        new_status = "slave";
        orientation = "right";
      };

      window_rule = [
        {
          name = "battlenet-gamescope-window";
          match.class = "^gamescope$";
          match.title = "^Battle\\.net.*$";
          float = true;
          size = "1600 900";
          center = true;
        }
        {
          name = "starcraft-gamescope-pane";
          match.class = "^gamescope$";
          match.title = "^StarCraft II$";
          tile = true;
          fullscreen_state = "0 0";
          suppress_event = "fullscreen maximize fullscreenoutput";
          content = "game";
          border_size = 0;
          rounding = 0;
          no_shadow = true;
          confine_pointer = true;
          no_shortcuts_inhibit = true;
          render_unfocused = true;
          idle_inhibit = "always";
        }
      ];
    };

    # Enable the game-pane layout only on the workspace containing the outer
    # Gamescope window, restoring normal dwindle behavior when it leaves.
    extraConfig = builtins.readFile ./hyprland.lua;
  };
}
