{ lib, pkgs, ... }:

let
  terminal = "ghostty";
  wallpaper = "${pkgs.nixos-artwork.wallpapers.gradient-grey.gnomeFilePath}";
in
{
  home.packages = [ pkgs.hyprpaper ];

  xdg.configFile."hypr/hyprpaper.conf".text = ''
    preload = ${wallpaper}
    wallpaper = ,${wallpaper}
    splash = false
    ipc = off
  '';

  wayland.windowManager.hyprland = {
    enable = true;
    systemd.enable = false;
    settings = {
      "$mod" = "SUPER";

      ecosystem = {
        no_update_news = true;
      };

      monitor = [
        # Fallback for any unspecified monitor: preferred mode, auto-placed,
        # scale 1. Matches Hyprland's built-in default; declared explicitly
        # so per-monitor overrides have a documented place to live.
        ", preferred, auto, 1"
      ];

      exec-once = [
        "waybar"
        "mako"
        "blueman-applet"
        "hyprpaper"
      ];

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
        kb_variant = "cat,";
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
      ];

      bind = [
        "$mod, Return, exec, ${terminal}"
        "$mod, D, exec, rofi -show drun"
        "$mod SHIFT, Q, killactive"
        "$mod, F, fullscreen"
        "$mod SHIFT, Space, togglefloating"
        "$mod, R, submap, resize"
        "$mod SHIFT, E, exit"
        "$mod, F12, exec, hyprctl switchxkblayout all next"

        "$mod, H, movefocus, l"
        "$mod, J, movefocus, d"
        "$mod, K, movefocus, u"
        "$mod, L, movefocus, r"
        "$mod SHIFT, H, movewindow, l"
        "$mod SHIFT, J, movewindow, d"
        "$mod SHIFT, K, movewindow, u"
        "$mod SHIFT, L, movewindow, r"

        "$mod CTRL, H, moveworkspacetomonitor, current -1"
        "$mod CTRL, L, moveworkspacetomonitor, current +1"

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
      ];

      binde = [
        "$mod SHIFT, right, resizeactive, 30 0"
        "$mod SHIFT, left, resizeactive, -30 0"
        "$mod SHIFT, up, resizeactive, 0 -30"
        "$mod SHIFT, down, resizeactive, 0 30"
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

  programs.waybar = {
    enable = true;
    settings.mainBar = {
      layer = "top";
      position = "top";
      modules-left = [ "hyprland/workspaces" ];
      modules-center = [ "hyprland/window" ];
      modules-right = [ "hyprland/language" "pulseaudio" "network" "battery" "clock" ];
      "hyprland/language" = {
        format = "{}";
      };
      battery = {
        format = "{capacity}%";
        format-charging = "{capacity}%+";
      };
      clock = {
        format = "{:%Y-%m-%d %H:%M}";
      };
      network = {
        format-wifi = "{essid}";
        format-ethernet = "wired";
        format-disconnected = "offline";
      };
      pulseaudio = {
        format = "{volume}%";
        format-muted = "muted";
      };
    };
    style = ''
      * {
        border: none;
        border-radius: 0;
        font-family: JetBrainsMono Nerd Font, monospace;
        font-size: 12px;
      }

      window#waybar {
        background: rgba(20, 18, 28, 0.92);
        color: #e0def4;
      }

      #workspaces button,
      #clock,
      #battery,
      #network,
      #pulseaudio,
      #language {
        padding: 0 10px;
      }

      #workspaces button.active {
        color: #9ccfd8;
      }
    '';
  };
}
