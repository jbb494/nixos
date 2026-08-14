{ config, inputs, lib, pkgs, ... }:

let
  inherit (lib.generators) mkLuaInline;
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
  eveAvailable = inputs.eve-protocol-observatory.available or false;
  eveRuntimePackages = if eveAvailable then inputs.eve-protocol-observatory.ags.packages.${pkgs.system} else [ ];
  eveShellModule = if eveAvailable then inputs.eve-protocol-observatory.ags.shellModule.${pkgs.system} else null;
  jbellavista-shell = pkgs.callPackage ../../packages/jbellavista-shell.nix {
    inherit eveRuntimePackages eveShellModule rollnrollShellModule rollnrollRuntimePackages;
  };
  mod = "SUPER";
  # Descriptors for hl.bind(keys, dispatcher[, flags]) calls in the generated
  # Lua config. `dispatcher` is a raw Lua expression string.
  mkBind = keys: dispatcher: { _args = [ keys (mkLuaInline dispatcher) ]; };
  mkBindFlags = keys: dispatcher: flags: { _args = [ keys (mkLuaInline dispatcher) flags ]; };
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
    # Hyprland 0.55+ deprecated hyprlang configs in favor of Lua.
    configType = "lua";
    settings = {
      config = {
        ecosystem = {
          no_update_news = true;
        };

        misc = {
          disable_hyprland_logo = true;
          disable_splash_rendering = true;
          force_default_wallpaper = 0;
        };

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
      };

      # Select each monitor's highest resolution, then highest refresh rate.
      monitor = {
        output = "";
        mode = "highres";
        position = "auto";
        scale = 1;
      };

      env = [
        { _args = [ "NIXOS_OZONE_WL" "1" ]; }
        { _args = [ "QT_QPA_PLATFORM" "wayland;xcb" ]; }
      ];

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

      # jbellavista-shell and mako run as systemd user services (see above and
      # home.nix) so nixos-rebuild switch restarts them when they change.
      on = {
        _args = [
          "hyprland.start"
          (mkLuaInline ''
            function()
              hl.exec_cmd("playerctld daemon")
              hl.exec_cmd("${pkgs.hyprpaper}/bin/hyprpaper")
            end'')
        ];
      };

      bind = [
        (mkBind "${mod} + Return" ''hl.dsp.exec_cmd("${terminal}")'')
        (mkBind "${mod} + D" ''hl.dsp.exec_cmd("rofi -show drun")'')
        (mkBind "${mod} + SHIFT + Q" "hl.dsp.window.close()")
        (mkBind "${mod} + mouse:274" "hl.dsp.window.close()")
        (mkBind "${mod} + SHIFT + Space" ''hl.dsp.window.float({ action = "toggle" })'')
        (mkBind "${mod} + E" ''hl.dsp.exec_cmd("hyprlock --grace 0 --immediate-render --no-fade-in")'')
        (mkBind "${mod} + period" "hl.dsp.exit()")
        (mkBind "${mod} + F12" ''hl.dsp.exec_cmd("hyprctl switchxkblayout all next")'')
        (mkBind "${mod} + O" ''hl.dsp.exec_cmd("${tmuxProjectsBin} oc-queue pop")'')
        (mkBind "${mod} + H" ''hl.dsp.focus({ direction = "left" })'')
        (mkBind "${mod} + J" ''hl.dsp.focus({ direction = "down" })'')
        (mkBind "${mod} + K" ''hl.dsp.focus({ direction = "up" })'')
        (mkBind "${mod} + L" ''hl.dsp.focus({ direction = "right" })'')
        (mkBind "${mod} + SHIFT + H" ''hl.dsp.window.move({ direction = "left" })'')
        (mkBind "${mod} + SHIFT + J" ''hl.dsp.window.move({ direction = "down" })'')
        (mkBind "${mod} + SHIFT + K" ''hl.dsp.window.move({ direction = "up" })'')
        (mkBind "${mod} + SHIFT + L" ''hl.dsp.window.move({ direction = "right" })'')

        (mkBind "${mod} + CTRL + H" ''hl.dsp.workspace.move({ monitor = "-1" })'')
        (mkBind "${mod} + CTRL + L" ''hl.dsp.workspace.move({ monitor = "+1" })'')
      ]
      # Top-row digits by scancode: layout-independent on both keyboards.
      # code:10 .. code:19 map to workspaces 1 .. 10.
      ++ lib.concatMap
        (i: [
          (mkBind "${mod} + code:${toString (i + 9)}" "hl.dsp.focus({ workspace = ${toString i} })")
          (mkBind "${mod} + SHIFT + code:${toString (i + 9)}" "hl.dsp.window.move({ workspace = ${toString i} })")
        ])
        (lib.range 1 10)
      ++ [
        (mkBind "XF86AudioRaiseVolume" ''hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+")'')
        (mkBind "XF86AudioLowerVolume" ''hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-")'')
        (mkBind "XF86AudioMute" ''hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle")'')
        (mkBind "XF86MonBrightnessUp" ''hl.dsp.exec_cmd("brightnessctl set +10%")'')
        (mkBind "XF86MonBrightnessDown" ''hl.dsp.exec_cmd("brightnessctl set 10%-")'')
        (mkBind "XF86AudioPlay" ''hl.dsp.exec_cmd("playerctl -p playerctld play-pause")'')
        (mkBind "XF86AudioPause" ''hl.dsp.exec_cmd("playerctl -p playerctld play-pause")'')
        (mkBind "XF86AudioNext" ''hl.dsp.exec_cmd("playerctl -p playerctld next")'')
        (mkBind "XF86AudioPrev" ''hl.dsp.exec_cmd("playerctl -p playerctld previous")'')
        (mkBind "XF86AudioStop" ''hl.dsp.exec_cmd("playerctl -p playerctld stop")'')

        # Run layout changes on F-key release; the scripts then wait briefly so
        # rebuilding XKB cannot swallow the release of Super.
        (mkBindFlags "${mod} + code:67" ''hl.dsp.exec_cmd("${keyboardNormalMode}/bin/keyboard-normal-mode")'' { release = true; })
        (mkBindFlags "${mod} + code:68" ''hl.dsp.exec_cmd("${keyboardGamingMode}/bin/keyboard-gaming-mode")'' { release = true; })

        (mkBindFlags "${mod} + SHIFT + right" "hl.dsp.window.resize({ x = 30, y = 0, relative = true })" { repeating = true; })
        (mkBindFlags "${mod} + SHIFT + left" "hl.dsp.window.resize({ x = -30, y = 0, relative = true })" { repeating = true; })
        (mkBindFlags "${mod} + SHIFT + up" "hl.dsp.window.resize({ x = 0, y = -30, relative = true })" { repeating = true; })
        (mkBindFlags "${mod} + SHIFT + down" "hl.dsp.window.resize({ x = 0, y = 30, relative = true })" { repeating = true; })

        (mkBindFlags "switch:on:Lid Switch" ''hl.dsp.exec_cmd("${lockAndSuspend}/bin/lock-and-suspend")'' { locked = true; })

        (mkBindFlags "${mod} + mouse:272" "hl.dsp.window.drag()" { mouse = true; })
        (mkBindFlags "${mod} + mouse:273" "hl.dsp.window.resize()" { mouse = true; })
      ];
    };

    submaps.resize.settings.bind = [
      (mkBindFlags "h" "hl.dsp.window.resize({ x = -30, y = 0, relative = true })" { repeating = true; })
      (mkBindFlags "j" "hl.dsp.window.resize({ x = 0, y = 30, relative = true })" { repeating = true; })
      (mkBindFlags "k" "hl.dsp.window.resize({ x = 0, y = -30, relative = true })" { repeating = true; })
      (mkBindFlags "l" "hl.dsp.window.resize({ x = 30, y = 0, relative = true })" { repeating = true; })
      (mkBind "escape" ''hl.dsp.submap("reset")'')
      (mkBind "return" ''hl.dsp.submap("reset")'')
    ];
  };
}
