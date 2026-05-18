{
  description = "Stub rollnroll devtools input for non-rollnroll machines";

  outputs = { self }: {
    isStub = true;

    homeManagerModules.default = { lib, ... }: {
      options.programs.rollnroll-devtools = {
        enable = lib.mkEnableOption "rollnroll devtools";
        enableZshIntegration = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Whether to add rollnroll devtools shell integration.";
        };
        ags = {
          shellModule = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "AGS shell module provided by RollnRoll devtools.";
          };
          runtimePackages = lib.mkOption {
            type = lib.types.listOf lib.types.package;
            default = [ ];
            description = "Runtime packages required by the RollnRoll AGS shell module.";
          };
        };
      };
    };
  };
}
