{
  claude = {
    guestModule = ./guests/claude.nix;
    defaults = {
      mem = 4096; vcpu = 2;
      configDirName = ".claude";
      persistDirs = [ "projects" "sessions" "statsig" "telemetry" ];
      allowedDomains = [
        "api.anthropic.com"
        "statsig.anthropic.com"
        "sentry.io"
      ];
    };
  };
  codex = {
    guestModule = ./guests/codex.nix;
    defaults = {
      mem = 4096; vcpu = 2;
      configDirName = ".codex";
      persistDirs = [ "projects" "sessions" "statsig" "telemetry" ];
      allowedDomains = [
        "api.openai.com"
        "chatgpt.com"
        "sentry.io"
      ];
    };
  };
}
