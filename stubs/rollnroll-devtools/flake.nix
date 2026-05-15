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
      };
    };
  };
}
