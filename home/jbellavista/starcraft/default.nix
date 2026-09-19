{ lib, osConfig, pkgs, ... }:

let
  starcraftGamescope = pkgs.writeShellApplication {
    name = "starcraft-gamescope";
    runtimeInputs = [ pkgs.gamescope ];
    text = ''
      exec gamescope \
        --output-width 2560 \
        --output-height 1440 \
        --nested-width 2560 \
        --nested-height 1440 \
        --borderless \
        -- "$@"
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
in
lib.mkIf (osConfig.networking.hostName == "desktop") {
  home.packages = [ starcraftGamescope ];

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
