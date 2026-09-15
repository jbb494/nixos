{ config, lib, pkgs, ... }:

let
  cfg = config.programs.summon;
  summonPackage = pkgs.callPackage ../../packages/summon.nix { };
  enabledEntries = lib.filterAttrs (_: entry: entry.enable) cfg.entries;
  configFile = pkgs.writeText "summon.json" (builtins.toJSON {
    apps = lib.mapAttrs (identifier: entry: {
      command = entry.command;
      class = entry.windowClass;
      title = entry.title;
      workingDirectory = entry.workingDirectory;
      environment = entry.environment;
      preload = entry.preload;
      maxWidth = entry.geometry.maxWidth;
      maxHeight = entry.geometry.maxHeight;
      widthRatio = entry.geometry.widthRatio;
      heightRatio = entry.geometry.heightRatio;
    }) enabledEntries;
  });
  desktopText = identifier: entry: ''
    [Desktop Entry]
    Type=Application
    Name=${entry.desktop.name}
    GenericName=${entry.desktop.genericName}
    Comment=${entry.desktop.comment}
    Exec=${summonPackage}/bin/summonctl open ${identifier}
    Icon=${entry.desktop.icon}
    Terminal=false
    StartupNotify=${if entry.desktop.startupNotify then "true" else "false"}
    StartupWMClass=${entry.windowClass}
    Categories=${lib.concatStringsSep ";" entry.desktop.categories};
    Keywords=${lib.concatStringsSep ";" entry.desktop.keywords};
  '';
  desktopFiles = lib.mapAttrs' (identifier: entry:
    lib.nameValuePair "applications/${entry.desktop.fileName}" {
      text = desktopText identifier entry;
    }
  ) (lib.filterAttrs (_: entry: entry.desktop.enable) enabledEntries);
in
{
  options.programs.summon = {
    enable = lib.mkEnableOption "the generic Summon popup service";

    entries = lib.mkOption {
      default = { };
      description = "Declarative popup applications exposed through Summon.";
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether to register this popup.";
          };

          command = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "Command argv executed directly in the popup terminal.";
          };

          windowClass = lib.mkOption {
            type = lib.types.strMatching "^[A-Za-z][A-Za-z0-9_.-]*\\.[A-Za-z0-9_.-]+$";
            description = "Unique GTK application ID and Hyprland window class.";
          };

          title = lib.mkOption {
            type = lib.types.str;
            default = name;
            description = "Popup window title.";
          };

          workingDirectory = lib.mkOption {
            type = lib.types.str;
            default = config.home.homeDirectory;
            description = "Initial working directory for the popup command.";
          };

          environment = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            description = "Additional environment variables for the popup command.";
          };

          preload = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether to keep a hidden, ready popup surface.";
          };

          geometry = {
            maxWidth = lib.mkOption {
              type = lib.types.ints.positive;
              default = 1100;
            };
            maxHeight = lib.mkOption {
              type = lib.types.ints.positive;
              default = 820;
            };
            widthRatio = lib.mkOption {
              type = lib.types.numbers.between 0.1 1.0;
              default = 0.85;
            };
            heightRatio = lib.mkOption {
              type = lib.types.numbers.between 0.1 1.0;
              default = 0.85;
            };
          };

          desktop = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
            };
            fileName = lib.mkOption {
              type = lib.types.strMatching "^[A-Za-z0-9._-]+\\.desktop$";
              default = "${name}.desktop";
            };
            name = lib.mkOption {
              type = lib.types.str;
              default = name;
            };
            genericName = lib.mkOption {
              type = lib.types.str;
              default = "Desktop Popup";
            };
            comment = lib.mkOption {
              type = lib.types.str;
              default = "Open ${name}";
            };
            icon = lib.mkOption {
              type = lib.types.str;
              default = "utilities-terminal";
            };
            startupNotify = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };
            categories = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ "Utility" ];
            };
            keywords = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ name "popup" ];
            };
          };
        };
      }));
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = lib.mapAttrsToList (identifier: entry: {
      assertion = builtins.match "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$" identifier != null
        && entry.command != [ ]
        && lib.hasPrefix "/" (lib.head entry.command);
      message = "Summon entry ${identifier} must have a safe identifier and an absolute, non-empty command.";
    }) enabledEntries;

    home.packages = [ summonPackage ];
    xdg.enable = true;
    xdg.dataFile = desktopFiles;

    systemd.user.services.summon = {
      Unit = {
        Description = "Summon desktop popup broker";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        Type = "simple";
        ExecStart = "${summonPackage}/bin/summond --config ${configFile}";
        Restart = "on-failure";
        RestartSec = 1;
        TimeoutStopSec = 5;
        UMask = "0077";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
}
