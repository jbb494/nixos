{ config, pkgs, ... }:

let
  terminal = "ghostty";
  tmuxProjectsBin = "/etc/profiles/per-user/jbellavista/bin/tmux-projects";
  wallpaper = "${pkgs.nixos-artwork.wallpapers.catppuccin-mocha.gnomeFilePath}";
  lockAndSuspend = pkgs.writeShellApplication {
    name = "lock-and-suspend";
    runtimeInputs = with pkgs; [
      coreutils
      hyprlock
      systemd
    ];
    text = ''
      hyprlock --grace 0 --immediate-render --no-fade-in &
      sleep 1
      systemctl suspend
    '';
  };
  keyboardMode = { name, globalLayout, ergodoxLayout, layoutIndex, label, color }: pkgs.writeShellApplication {
    inherit name;
    runtimeInputs = [ pkgs.coreutils pkgs.hyprland ];
    text = ''
      # Let the shortcut modifiers be released before replacing the XKB map.
      sleep 0.35

      set_ergodox_layout() {
        local device="$1"
        hyprctl --quiet keyword "device[$device]:kb_layout" "${ergodoxLayout}"
        hyprctl --quiet keyword "device[$device]:kb_variant" ","
        hyprctl --quiet keyword "device[$device]:kb_options" "grp:alt_shift_toggle"
      }

      set_ergodox_layout zsa-technology-labs-ergodox-ez
      set_ergodox_layout zsa-technology-labs-ergodox-ez-keyboard

      hyprctl --quiet keyword input:kb_layout "${globalLayout}"
      hyprctl --quiet keyword input:kb_variant ","
      hyprctl --quiet keyword input:kb_options "grp:alt_shift_toggle"
      hyprctl --quiet switchxkblayout all ${toString layoutIndex}
      hyprctl notify 2 1500 "rgb(${color})" "${label}" || true
    '';
  };
  keyboardNormalMode = keyboardMode {
    name = "keyboard-normal-mode";
    globalLayout = "es,us";
    ergodoxLayout = "ergodox-dvorak,us";
    layoutIndex = 0;
    label = "Keyboard: normal";
    color = "a6e3a1";
  };
  keyboardGamingMode = keyboardMode {
    name = "keyboard-gaming-mode";
    globalLayout = "us,us";
    ergodoxLayout = "us,us";
    layoutIndex = 0;
    label = "Keyboard: QWERTY gaming";
    color = "f9e2af";
  };
  rollnrollShellModule = config.programs.rollnroll-devtools.ags.shellModule or null;
  rollnrollRuntimePackages = config.programs.rollnroll-devtools.ags.runtimePackages or [ ];
  jbellavista-shell = pkgs.callPackage ../../packages/jbellavista-shell.nix {
    inherit rollnrollShellModule rollnrollRuntimePackages;
  };
  monitorRules = [
    # Select each monitor's highest resolution, then highest refresh rate.
    ", highres, auto, 1"
  ];
in
{
  home.packages = [ jbellavista-shell pkgs.hyprlock pkgs.hyprpaper ];

  # Run the bar as a user service: sd-switch restarts it on every rebuild
  # where the package changed, so the running bar always matches the config.
  systemd.user.services.jbellavista-shell = {
    Unit = {
      Description = "jbellavista AGS shell";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = "${jbellavista-shell}/bin/jbellavista-shell";
      Restart = "on-failure";
      RestartSec = 1;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  xdg.configFile."hypr/hyprpaper.conf".text = ''
    wallpaper {
      monitor =
      path = ${wallpaper}
    }

    splash = false
    ipc = off
  '';

  xdg.configFile."hypr/hyprlock.conf".text = ''
    general {
      disable_loading_bar = true
      hide_cursor = true
    }

    background {
      monitor =
      path = screenshot
      blur_passes = 2
      blur_size = 6
    }

    input-field {
      monitor =
      size = 240, 52
      outline_thickness = 2
      dots_size = 0.25
      dots_spacing = 0.25
      dots_center = true
      outer_color = rgba(ffffff55)
      inner_color = rgba(111111aa)
      font_color = rgba(ffffffff)
      fade_on_empty = false
      placeholder_text = <i>Password</i>
      position = 0, -40
      halign = center
      valign = center
    }
  '';

  wayland.windowManager.hyprland = {
    enable = true;
    systemd.enable = false;
    settings = {
      "$mod" = "SUPER";

      ecosystem = {
        no_update_news = true;
      };

      monitor = monitorRules;

      # jbellavista-shell and mako run as systemd user services (see below and
      # home.nix) so nixos-rebuild switch restarts them when they change.
      exec-once = [
        "playerctld daemon"
        "${pkgs.hyprpaper}/bin/hyprpaper"
      ];

      misc = {
        disable_hyprland_logo = true;
        disable_splash_rendering = true;
        force_default_wallpaper = 0;
      };

      env = [
        "NIXOS_OZONE_WL,1"
        "QT_QPA_PLATFORM,wayland;xcb"
      ];

      general = {
        gaps_in = 4;
        gaps_out = 8;
        border_size = 2;
        layout = "dwindle";
      };

      decoration = {
        rounding = 8;
        blur.enabled = false;
      };

      animations.enabled = false;

      input = {
        kb_layout = "es,us";
        kb_variant = ",";
        kb_options = "grp:alt_shift_toggle";
        follow_mouse = 0;
        touchpad.natural_scroll = true;
        # Resolve binds against the active keyboard's layout, not the first one.
        resolve_binds_by_sym = true;
      };

      device = [
        {
          name = "zsa-technology-labs-ergodox-ez";
          kb_layout = "ergodox-dvorak,us";
          kb_variant = ",";
          kb_options = "grp:alt_shift_toggle";
        }
        {
          name = "zsa-technology-labs-ergodox-ez-keyboard";
          kb_layout = "ergodox-dvorak,us";
          kb_variant = ",";
          kb_options = "grp:alt_shift_toggle";
        }
        {
          name = "at-translated-set-2-keyboard";
          kb_layout = "es,us";
          kb_variant = "cat,";
          kb_options = "grp:alt_shift_toggle";
        }
        {
          name = "sonix-calibur-v2-te";
          kb_layout = "es,us";
          kb_variant = ",";
          kb_options = "grp:alt_shift_toggle";
        }
        {
          name = "sonix-calibur-v2-te-2";
          kb_layout = "es,us";
          kb_variant = ",";
          kb_options = "grp:alt_shift_toggle";
        }
      ];

      bind = [
        "$mod, Return, exec, ${terminal}"
        "$mod, D, exec, rofi -show drun"
        "$mod SHIFT, Q, killactive"
        "$mod, mouse:274, killactive"
        "$mod SHIFT, Space, togglefloating"
        "$mod, E, exec, ${lockAndSuspend}/bin/lock-and-suspend"
        "$mod, period, exit"
        "$mod, F12, exec, hyprctl switchxkblayout all next"
        "$mod, O, exec, ${tmuxProjectsBin} oc-queue pop"
        "$mod, H, movefocus, l"
        "$mod, J, movefocus, d"
        "$mod, K, movefocus, u"
        "$mod, L, movefocus, r"
        "$mod SHIFT, H, movewindow, l"
        "$mod SHIFT, J, movewindow, d"
        "$mod SHIFT, K, movewindow, u"
        "$mod SHIFT, L, movewindow, r"

        "$mod CTRL, H, movecurrentworkspacetomonitor, -1"
        "$mod CTRL, L, movecurrentworkspacetomonitor, +1"

        # Top-row digits by scancode: layout-independent on both keyboards.
        "$mod, code:10, workspace, 1"
        "$mod, code:11, workspace, 2"
        "$mod, code:12, workspace, 3"
        "$mod, code:13, workspace, 4"
        "$mod, code:14, workspace, 5"
        "$mod, code:15, workspace, 6"
        "$mod, code:16, workspace, 7"
        "$mod, code:17, workspace, 8"
        "$mod, code:18, workspace, 9"
        "$mod, code:19, workspace, 10"
        "$mod SHIFT, code:10, movetoworkspace, 1"
        "$mod SHIFT, code:11, movetoworkspace, 2"
        "$mod SHIFT, code:12, movetoworkspace, 3"
        "$mod SHIFT, code:13, movetoworkspace, 4"
        "$mod SHIFT, code:14, movetoworkspace, 5"
        "$mod SHIFT, code:15, movetoworkspace, 6"
        "$mod SHIFT, code:16, movetoworkspace, 7"
        "$mod SHIFT, code:17, movetoworkspace, 8"
        "$mod SHIFT, code:18, movetoworkspace, 9"
        "$mod SHIFT, code:19, movetoworkspace, 10"

        ", XF86AudioRaiseVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+"
        ", XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"
        ", XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"
        ", XF86MonBrightnessUp, exec, brightnessctl set +10%"
        ", XF86MonBrightnessDown, exec, brightnessctl set 10%-"
        ", XF86AudioPlay, exec, playerctl -p playerctld play-pause"
        ", XF86AudioPause, exec, playerctl -p playerctld play-pause"
        ", XF86AudioNext, exec, playerctl -p playerctld next"
        ", XF86AudioPrev, exec, playerctl -p playerctld previous"
        ", XF86AudioStop, exec, playerctl -p playerctld stop"
      ];

      # Run layout changes on F-key release; the scripts then wait briefly so
      # rebuilding XKB cannot swallow the release of Super.
      bindr = [
        "$mod, code:67, exec, ${keyboardNormalMode}/bin/keyboard-normal-mode"
        "$mod, code:68, exec, ${keyboardGamingMode}/bin/keyboard-gaming-mode"
      ];

      binde = [
        "$mod SHIFT, right, resizeactive, 30 0"
        "$mod SHIFT, left, resizeactive, -30 0"
        "$mod SHIFT, up, resizeactive, 0 -30"
        "$mod SHIFT, down, resizeactive, 0 30"
      ];

      bindl = [
        ", switch:on:Lid Switch, exec, ${lockAndSuspend}/bin/lock-and-suspend"
      ];

      bindm = [
        "$mod, mouse:272, movewindow"
        "$mod, mouse:273, resizewindow"
      ];

    };
    extraConfig = ''
      submap = resize
      binde = , h, resizeactive, -30 0
      binde = , j, resizeactive, 0 30
      binde = , k, resizeactive, 0 -30
      binde = , l, resizeactive, 30 0
      bind = , escape, submap, reset
      bind = , return, submap, reset
      submap = reset
    '';
  };
}
