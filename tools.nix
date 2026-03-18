{
  claude = {
    guestModule = ./guests/claude.nix;
    defaults = {
      mem = 4096; vcpu = 2;
      configDirName = ".claude";
      persistDirs = [ "projects" "sessions" "statsig" "telemetry" ];
    };
  };
  codex = {
    guestModule = ./guests/codex.nix;
    defaults = {
      mem = 4096; vcpu = 2;
      configDirName = ".codex";
      persistDirs = [ "projects" "sessions" "statsig" "telemetry" ];
    };
  };
}
