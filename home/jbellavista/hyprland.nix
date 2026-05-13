{ lib, pkgs, ... }:

let
  terminal = "ghostty";
  wallpaper = "${pkgs.nixos-artwork.wallpapers.gradient-grey.gnomeFilePath}";
  wallpaperMonitors = [ "eDP-1" "DP-1" ];
  hyprwhspr = lib.getExe pkgs.hyprwhspr-rs;
  hyprwhsprModel = pkgs.fetchurl {
    url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin";
    hash = "sha256-oDd5yG3zMjB19eeWyyzlAp8A7Ihp7uP9+4l6/jbG0AI=";
  };
in
{
  home.packages = [ pkgs.hyprlock pkgs.hyprpaper pkgs.hyprwhspr-rs ];

  xdg.dataFile."hyprwhspr-rs/models/ggml-base.en.bin".source = hyprwhsprModel;

  xdg.configFile."hyprwhspr-rs/config.jsonc".text = ''
    {
      "audio_feedback": true,
      "auto_copy_clipboard": true,
      "transcription": {
        "provider": "whisper_cpp",
        "whisper_cpp": {
          "model": "base.en",
          "models_dirs": ["~/.local/share/hyprwhspr-rs/models"]
        }
      }
    }
  '';

  xdg.configFile."hypr/hyprpaper.conf".text = ''
    ${lib.concatMapStringsSep "\n\n" (monitor: ''
      wallpaper {
        monitor = ${monitor}
        path = ${wallpaper}
      }
    '') wallpaperMonitors}

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

      monitor = [
        # Fallback for any unspecified monitor: preferred mode, auto-placed,
        # scale 1. Matches Hyprland's built-in default; declared explicitly
        # so per-monitor overrides have a documented place to live.
        ", preferred, auto, 1"
      ];

      exec-once = [
        "${pkgs.hyprpanel}/bin/hyprpanel"
        "blueman-applet"
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
        "$mod, mouse:274, killactive"
        "$mod, F, fullscreen"
        "$mod SHIFT, Space, togglefloating"
        "$mod, R, submap, resize"
        "$mod, E, exec, ${pkgs.hyprlock}/bin/hyprlock"
        "$mod, period, exit"
        "$mod, F12, exec, hyprctl switchxkblayout all next"
        ", Print, exec, ${hyprwhspr} record start"

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
        ", XF86AudioPlay, exec, playerctl play-pause"
        ", XF86AudioPause, exec, playerctl play-pause"
        ", XF86AudioNext, exec, playerctl next"
        ", XF86AudioPrev, exec, playerctl previous"
        ", XF86AudioStop, exec, playerctl stop"
      ];

      binde = [
        "$mod SHIFT, right, resizeactive, 30 0"
        "$mod SHIFT, left, resizeactive, -30 0"
        "$mod SHIFT, up, resizeactive, 0 -30"
        "$mod SHIFT, down, resizeactive, 0 30"
      ];

      bindr = [
        ", Print, exec, ${hyprwhspr} record stop"
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

  programs.hyprpanel = {
    enable = true;
    systemd.enable = false;
    settings = {
      wallpaper.enable = false;

      bar = {
        layouts."*" = {
          left = [ "dashboard" "workspaces" ];
          middle = [ ];
          right = [ "cpu" "ram" "volume" "network" "bluetooth" "battery" "systray" "clock" "notifications" ];
        };
        launcher.icon = "";
        volume.label = false;
        network = {
          label = false;
          showWifiInfo = true;
          truncation_size = 18;
        };
        bluetooth.label = false;
        battery.label = true;
        clock = {
          format = "%H:%M";
          showIcon = false;
        };
        workspaces = {
          show_numbered = true;
          show_icons = false;
        };
      };
      theme = {
        bar = {
          scaling = 85;
          floating = true;
          opacity = 92;
          transparent = false;
          buttons = {
            style = "default";
            monochrome = false;
            padding_y = "0.1rem";
            y_margins = "0.25em";
          };
        };
        font = {
          name = "JetBrainsMono Nerd Font";
          size = "11px";
        };
      };
    };
  };
}
