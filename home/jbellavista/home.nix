{ inputs
, lib
, pkgs
, ...
}:

let
  tms = lib.getExe pkgs.tmux-sessionizer;

  screenshot-full = pkgs.writeShellApplication {
    name = "screenshot-full";
    runtimeInputs = with pkgs; [
      grim
      swappy
    ];
    text = ''
      grim - | swappy -f -
    '';
  };

  screenshot-region = pkgs.writeShellApplication {
    name = "screenshot-region";
    runtimeInputs = with pkgs; [
      grim
      slurp
      swappy
    ];
    text = ''
      geometry="$(slurp)"
      grim -g "$geometry" - | swappy -f -
    '';
  };

  hypr-summon = pkgs.writeShellApplication {
    name = "hypr-summon";
    runtimeInputs = with pkgs; [
      coreutils
      hyprland
      jq
    ];
    text = ''
      set -euo pipefail

      matcher=""
      make_float=0

      while [[ $# -gt 0 ]]; do
        case "$1" in
          --match)
            if [[ $# -lt 2 ]]; then
              printf 'hypr-summon: --match requires a regex\n' >&2
              exit 2
            fi
            matcher="$2"
            shift 2
            ;;
          --float)
            make_float=1
            shift
            ;;
          --)
            shift
            break
            ;;
          *)
            break
            ;;
        esac
      done

      if [[ -z "$matcher" || $# -eq 0 ]]; then
        printf 'usage: hypr-summon --match REGEX [--float] -- command [args...]\n' >&2
        exit 2
      fi

      clients_json="$(hyprctl clients -j 2>/dev/null || printf '[]')"
      address="$(${pkgs.jq}/bin/jq -r --arg re "$matcher" '
        map(select(
          ((.class // "") | test($re; "i")) or
          ((.initialClass // "") | test($re; "i")) or
          ((.title // "") | test($re; "i")) or
          ((.initialTitle // "") | test($re; "i"))
        ))[0].address // empty
      ' <<<"$clients_json")"

      if [[ -n "$address" ]]; then
        workspace="$(hyprctl activeworkspace -j | ${pkgs.jq}/bin/jq -r '.id // empty')"
        if [[ -n "$workspace" ]]; then
          hyprctl dispatch movetoworkspace "$workspace,address:$address" >/dev/null
        fi

        hyprctl dispatch focuswindow "address:$address" >/dev/null

        if [[ "$make_float" == "1" ]]; then
          hyprctl dispatch setfloating "address:$address" >/dev/null || true
          hyprctl dispatch centerwindow >/dev/null || true
        fi

        exit 0
      fi

      exec "$@"
    '';
  };

  tms-app = pkgs.writeShellApplication {
    name = "tms-app";
    runtimeInputs = with pkgs; [
      coreutils
      ghostty
      hyprland
      jq
      tmux
    ];
    text = ''
      set -euo pipefail

      tms_config_dir="''${XDG_RUNTIME_DIR:-/tmp}/tms-app"
      tms_config="$tms_config_dir/config.toml"
      mkdir -p "$tms_config_dir"
      rm -f "$tms_config"
      install -m 600 /dev/null "$tms_config"

      shopt -s nullglob
      worktrees=()
      for git_file in "$HOME"/*/*-worktrees/*/.git "$HOME"/*/worktrees/*/.git; do
        [[ -f "$git_file" ]] || continue
        worktrees+=("$(dirname "$git_file")")
      done
      shopt -u nullglob

      if [[ ''${#worktrees[@]} -gt 0 ]]; then
        printf 'bookmarks = [\n' >> "$tms_config"
        for worktree in "''${worktrees[@]}"; do
          printf '  %s,\n' "$(printf '%s' "$worktree" | jq -Rs .)" >> "$tms_config"
        done
        printf ']\n\n' >> "$tms_config"
      fi

      while IFS= read -r line || [[ -n "$line" ]]; do
        printf '%s\n' "$line" >> "$tms_config"
      done < "$HOME/.config/tms/config.toml"

      tmux_command=(tmux)
      tmux_socket="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/tmux-$(id -u)/default"
      if [[ -S "$tmux_socket" ]]; then
        tmux_command=(tmux -S "$tmux_socket")
      fi

      client="$("''${tmux_command[@]}" list-clients -F '#{client_activity} #{client_tty}' 2>/dev/null \
        | sort -rn \
        | while read -r _ tty; do printf '%s' "$tty"; break; done || true)"

      if [[ -n "$client" ]]; then
        address="$(hyprctl clients -j 2>/dev/null | jq -r '
          map(select(
            (.class // "") == "com.mitchellh.ghostty" or
            (.initialClass // "") == "com.mitchellh.ghostty"
          ))
          | sort_by(.focusHistoryID // 999999)
          | .[0].address // empty
        ')"

        if [[ -n "$address" ]]; then
          hyprctl dispatch focuswindow "address:$address" >/dev/null || true
        fi

        if "''${tmux_command[@]}" display-popup -t "$client" -E "env TMS_CONFIG_FILE=$tms_config ${tms}"; then
          exit 0
        fi
      fi

      exec ghostty -e env TMS_CONFIG_FILE="$tms_config" ${tms}
    '';
  };
in

{
  imports = [
    ./hyprland.nix
  ];

  home = {
    username = "jbellavista";
    homeDirectory = "/home/jbellavista";
    stateVersion = "25.11";
    sessionVariables = {
      EDITOR = "nvim";
      TERMINAL = "ghostty";
    };
    pointerCursor = {
      name = "Adwaita";
      package = pkgs.adwaita-icon-theme;
      size = 24;
      gtk.enable = true;
      x11.enable = true;
    };
    packages = with pkgs; [
      bat
      brightnessctl
      bun
      caddy
      cmake
      delta
      discord
      docker-compose
      gcc
      gettext
      ghostty
      gh
      go
      google-chrome
      grim
      jq
      kubectl
      lua-language-server
      nodejs_22
      obs-studio
      opencode
      networkmanagerapplet
      pavucontrol
      playerctl
      pnpm
      python311
      rofi
      slurp
      spotify
      stylua
      swappy
      typescript-language-server
      uv
      vscode-langservers-extracted
      wl-clipboard
    ]
    ++ [
      hypr-summon
      screenshot-full
      screenshot-region
      tms-app
    ]
    ++ lib.optional (pkgs ? mise) pkgs.mise
    ++ lib.optional (pkgs ? skaffold) pkgs.skaffold;
  };

  programs.home-manager.enable = true;

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  programs.fzf = {
    enable = true;
    enableZshIntegration = true;
  };

  programs.git = {
    enable = true;
    includes = [
      {
        condition = "gitdir:~/personal/";
        contents.user = {
          name = "Joan Bellavista Bartroli";
          email = "jbb494@gmail.com";
        };
      }
    ];
    settings = {
      branch.sort = "-committerdate";
      column.ui = "auto";
      user.name = "Joan Bellavista Bartroli";
      diff = {
        algorithm = "histogram";
        colorMoved = "plain";
        mnemonicPrefix = true;
        renames = true;
      };
      fetch = {
        all = true;
        prune = true;
        pruneTags = true;
      };
      init.defaultBranch = "main";
      push = {
        autoSetupRemote = true;
        default = "simple";
        followTags = true;
      };
      rerere = {
        autoupdate = true;
        enabled = true;
      };
      tag.sort = "version:refname";
    };
  };

  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    includes = [ "~/.ssh/config.local" ];
    matchBlocks."github.com-personal" = {
      hostname = "github.com";
      user = "git";
      identityFile = "~/.ssh/id_ed25519_personal";
      identitiesOnly = true;
    };
  };

  programs.rofi = {
    enable = true;
    package = pkgs.rofi;
  };

  programs.tmux = {
    enable = true;
    baseIndex = 1;
    clock24 = true;
    escapeTime = 0;
    historyLimit = 200000;
    keyMode = "vi";
    prefix = "C-a";
    terminal = "tmux-256color";
    plugins = with pkgs.tmuxPlugins; [
      continuum
      resurrect
      yank
    ];
    extraConfig = ''
      set -as terminal-overrides ',ghostty*:Tc'
      set -g display-time 4000
      set -g status-interval 5
      set -g focus-events on
      setw -g aggressive-resize on

      bind r source-file ~/.config/tmux/tmux.conf
      bind -T copy-mode-vi v send-keys -X begin-selection
      bind -T copy-mode-vi y send-keys -X copy-pipe 'wl-copy' \; send -X clear-selection
      bind -T copy-mode-vi ] send-keys -X next-prompt
      bind -T copy-mode-vi [ send-keys -X previous-prompt

      bind ^ last-window
      bind k select-pane -U
      bind j select-pane -D
      bind h select-pane -L
      bind l select-pane -R

      set -g status-right ' #(${tms} sessions)'
      unbind-key F
      bind -r '(' switch-client -p\; refresh-client -S
      bind -r ')' switch-client -n\; refresh-client -S
      bind -r N display-popup -E 'TMS_CONFIG_FILE=~/.config/tms/config-nvim-repos.toml ${tms}'
      bind -r f display-popup -E '${tms} switch'
      bind -r w display-popup -E '${tms} windows'
      bind -r o last-window
      bind -r X kill-session
    '';
  };

  programs.zoxide = {
    enable = true;
    enableZshIntegration = true;
  };

  programs.zsh = {
    enable = true;
    autosuggestion.enable = true;
    enableCompletion = true;
    shellAliases = {
      ta = "tmux attach";
      v = "nvim";
    };
    syntaxHighlighting.enable = true;
    initContent = ''
      bindkey -v
      bindkey -M viins '^P' history-beginning-search-backward
      bindkey -M viins '^N' history-beginning-search-forward

      ${lib.optionalString (pkgs ? mise) ''eval "$(${pkgs.mise}/bin/mise activate zsh)"''}

      opencode() {
        local profile=""

        case "$PWD/" in
          "$HOME/personal/"*)
            local dir="$PWD"
            while [[ "$dir/" == "$HOME/personal/"* ]]; do
              if [[ -e "$dir/.opencode-default" ]]; then
                command opencode "$@"
                return
              fi

              [[ "$dir" == "$HOME/personal" ]] && break
              dir="${dir:h}"
            done
            profile="personal"
            ;;
        esac

        if [[ -z "$profile" ]]; then
          command opencode "$@"
          return
        fi

        XDG_DATA_HOME="$HOME/.local/share/opencode-profiles/$profile/data" \
          XDG_STATE_HOME="$HOME/.local/state/opencode-profiles/$profile" \
          XDG_CACHE_HOME="$HOME/.cache/opencode-profiles/$profile" \
          command opencode "$@"
      }

      if [[ -f "$HOME/.cargo/env" ]]; then
        source "$HOME/.cargo/env"
      fi

      if [[ -f "$HOME/.zsh_local" ]]; then
        source "$HOME/.zsh_local"
      fi
    '';
  };

  gtk = {
    enable = true;
    theme = {
      name = "Adwaita-dark";
      package = pkgs.gnome-themes-extra;
    };
    iconTheme = {
      name = "Adwaita";
      package = pkgs.adwaita-icon-theme;
    };
    gtk3.extraConfig.gtk-application-prefer-dark-theme = 1;
    gtk4 = {
      theme = {
        name = "Adwaita-dark";
        package = pkgs.gnome-themes-extra;
      };
      extraConfig.gtk-application-prefer-dark-theme = 1;
    };
  };

  qt = {
    enable = true;
    platformTheme.name = "gtk";
    style.name = "adwaita-dark";
  };

  dconf.settings = {
    "org/gnome/desktop/interface" = {
      color-scheme = "prefer-dark";
      gtk-theme = "Adwaita-dark";
      cursor-theme = "Adwaita";
      cursor-size = 24;
    };
  };

  # Shadow system desktop entries so app launchers behave well under Hyprland.
  # Apps that cannot open a second instance are moved to the current workspace.
  xdg.dataFile = {
    "applications/google-chrome.desktop".text = ''
      [Desktop Entry]
      Version=1.0
      Name=Google Chrome
      GenericName=Web Browser
      Comment=Access the Internet
      Exec=${pkgs.google-chrome}/bin/google-chrome-stable --new-window %U
      StartupNotify=true
      StartupWMClass=Google-chrome
      Terminal=false
      Icon=google-chrome
      Type=Application
      Categories=Network;WebBrowser;
      MimeType=application/pdf;application/rdf+xml;application/rss+xml;application/xhtml+xml;application/xhtml_xml;application/xml;image/gif;image/jpeg;image/png;image/webp;text/html;text/xml;x-scheme-handler/http;x-scheme-handler/https;
      Actions=new-window;new-private-window;

      [Desktop Action new-window]
      Name=New Window
      Exec=${pkgs.google-chrome}/bin/google-chrome-stable --new-window

      [Desktop Action new-private-window]
      Name=New Incognito Window
      Exec=${pkgs.google-chrome}/bin/google-chrome-stable --incognito
    '';

    "applications/blueman-manager.desktop".text = ''
      [Desktop Entry]
      Name=Bluetooth Manager
      Comment=Blueman Bluetooth Manager
      Exec=${hypr-summon}/bin/hypr-summon --match "blueman-manager|blueman|bluetooth manager" -- ${pkgs.blueman}/bin/blueman-manager
      Icon=blueman
      StartupNotify=true
      Terminal=false
      Type=Application
      Categories=GTK;GNOME;Settings;HardwareSettings;
    '';

    "applications/org.pulseaudio.pavucontrol.desktop".text = ''
      [Desktop Entry]
      Version=1.0
      Name=Volume Control
      GenericName=Volume Control
      Comment=Adjust the volume level
      Exec=${hypr-summon}/bin/hypr-summon --match "pavucontrol|org[.]pulseaudio[.]pavucontrol|volume control" -- ${pkgs.pavucontrol}/bin/pavucontrol
      Icon=org.pulseaudio.pavucontrol
      StartupNotify=true
      Terminal=false
      Type=Application
      Categories=AudioVideo;Audio;Mixer;GTK;Settings;X-XFCE-SettingsDialog;X-XFCE-HardwareSettings;
      Keywords=pavucontrol;PulseAudio;Microphone;Volume;Audio;Mixer;Output;Input;Devices;Playback;Recording;
    '';

    "applications/nm-connection-editor.desktop".text = ''
      [Desktop Entry]
      Name=Network Connections
      Comment=Manage and change your network connection settings
      Exec=${hypr-summon}/bin/hypr-summon --match "nm-connection-editor|network connections" -- ${pkgs.networkmanagerapplet}/bin/nm-connection-editor
      Icon=preferences-system-network
      StartupNotify=true
      Terminal=false
      Type=Application
      Categories=GNOME;GTK;Settings;X-GNOME-NetworkSettings;
      Keywords=Network;Connections;Wi-Fi;Wifi;Ethernet;
    '';

    "applications/screenshot-full.desktop".text = ''
      [Desktop Entry]
      Name=Screenshot Full Screen
      GenericName=Screenshot Tool
      Comment=Capture the full screen and edit it in Swappy
      Exec=${screenshot-full}/bin/screenshot-full
      Icon=camera-photo
      StartupNotify=false
      Terminal=false
      Type=Application
      Categories=Utility;Graphics;
      Keywords=Screenshot;Screen;Capture;Swappy;Grim;
    '';

    "applications/screenshot-region.desktop".text = ''
      [Desktop Entry]
      Name=Screenshot Region
      GenericName=Screenshot Tool
      Comment=Select a screen region and edit it in Swappy
      Exec=${screenshot-region}/bin/screenshot-region
      Icon=camera-photo
      StartupNotify=false
      Terminal=false
      Type=Application
      Categories=Utility;Graphics;
      Keywords=Screenshot;Screen;Capture;Region;Swappy;Grim;Slurp;
    '';

    "applications/tms.desktop".text = ''
      [Desktop Entry]
      Name=TMS
      GenericName=Tmux Sessionizer
      Comment=Open tmux-sessionizer in the active tmux client
      Exec=${tms-app}/bin/tms-app
      Icon=utilities-terminal
      StartupNotify=false
      Terminal=false
      Type=Application
      Categories=Development;Utility;TerminalEmulator;
      Keywords=tms;tmux;sessionizer;worktree;terminal;ghostty;
    '';
  };

  xdg.configFile = {
    "ghostty/config".text = ''
      font-family = JetBrainsMonoNL Nerd Font Mono
      font-feature = -calt, -liga, -dlig
    '';
    "nvim".source = inputs.nvim-config;
    "opencode/config.json".text = ''
      {
        "$schema": "https://opencode.ai/config.json",
        "share": "disabled"
      }
    '';
    "opencode/tui.json".text = ''
      {
        "$schema": "https://opencode.ai/tui.json",
        "keybinds": {
          "leader": "ctrl+x",
          "app_exit": "ctrl+c,<leader>q",
          "editor_open": "<leader>e",
          "theme_list": "<leader>t",
          "session_new": "<leader>n",
          "session_list": "<leader>l",
          "session_share": "<leader>s",
          "session_unshare": "<leader>u",
          "session_interrupt": "escape",
          "session_compact": "<leader>c",
          "messages_page_up": "pageup",
          "messages_page_down": "pagedown",
          "messages_half_page_up": "ctrl+u",
          "messages_half_page_down": "ctrl+d",
          "messages_first": "ctrl+g",
          "messages_last": "ctrl+alt+g",
          "messages_copy": "<leader>y",
          "messages_undo": "<leader>u",
          "messages_redo": "<leader>r",
          "model_list": "<leader>m",
          "input_clear": "ctrl+c",
          "input_paste": "ctrl+v",
          "input_submit": "return",
          "input_newline": "shift+return,ctrl+return,alt+return,ctrl+j",
          "history_previous": "ctrl+up",
          "history_next": "ctrl+down"
        }
      }
    '';
    "tms/config.toml".text = ''
      default_session = "default_session"
      search_submodules = true
      recursive_submodules = true
      full_path = true
      session_sort_order = "LastAttached"

      [[search_dirs]]
      path = "~/personal"
      depth = 2

      [[search_dirs]]
      path = "~/.local/src"
      depth = 1
    '';
    "tms/config-nvim-repos.toml".text = ''
      default_session = "default_session"
      search_submodules = true
      recursive_submodules = true
      full_path = true
      session_sort_order = "LastAttached"

      [[search_dirs]]
      path = "~/.local/share/nvim/lazy"
      depth = 1
    '';
  };
}
