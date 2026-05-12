{ inputs
, lib
, pkgs
, ...
}:

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
      opencode
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
      waybar
      wl-clipboard
    ]
    ++ lib.optional (pkgs ? mise) pkgs.mise
    ++ lib.optional (pkgs ? skaffold) pkgs.skaffold
    ++ lib.optional (pkgs ? tmux-sessionizer) pkgs.tmux-sessionizer;
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

      set -g status-right ' #(tms sessions)'
      bind -r '(' switch-client -p\; refresh-client -S
      bind -r ')' switch-client -n\; refresh-client -S
      bind -r N display-popup -E 'TMS_CONFIG_FILE=~/.config/tms/config-nvim-repos.toml tms'
      bind -r F display-popup -E 'tms'
      bind -r f display-popup -E 'tms switch'
      bind -r w display-popup -E 'tms windows'
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
      bindkey -M viins '^P' up-history
      bindkey -M viins '^N' down-history

      ${lib.optionalString (pkgs ? mise) ''eval "$(${pkgs.mise}/bin/mise activate zsh)"''}

      if [[ -f "$HOME/.cargo/env" ]]; then
        source "$HOME/.cargo/env"
      fi

      if [[ -f "$HOME/.zsh_local" ]]; then
        source "$HOME/.zsh_local"
      fi
    '';
  };

  services.mako = {
    enable = true;
    settings = {
      default-timeout = 8000;
      font = "JetBrainsMono Nerd Font 10";
      border-size = 2;
      border-radius = 8;
    };
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

  # Override Google Chrome's desktop entry so launching it always opens a new
  # window instead of focusing an existing one. Shadows the system .desktop via
  # XDG_DATA_DIRS precedence (~/.local/share takes priority).
  xdg.dataFile."applications/google-chrome.desktop".text = ''
    [Desktop Entry]
    Version=1.0
    Name=Google Chrome
    GenericName=Web Browser
    Comment=Access the Internet
    Exec=${pkgs.google-chrome}/bin/google-chrome-stable --new-window %U
    StartupNotify=true
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

  xdg.configFile = {
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
