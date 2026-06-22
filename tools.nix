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
  shell = {
    guestModule = ./guests/shell.nix;
    defaults = {
      mem = 2048; vcpu = 2;
      configDirName = ".llmjail-shell";
      persistDirs = [ ];
      # No domains whitelisted by default — debug shell runs offline unless
      # the user opts in with --allow-domain or --no-net-filter.
      allowedDomains = [ ];
    };
  };
  copilot = {
    guestModule = ./guests/copilot.nix;
    defaults = {
      mem = 4096; vcpu = 2;
      configDirName = ".copilot";
      persistDirs = [
        "logs"
        "session-state"
      ];
      persistFiles = [
        "command-history-state.json"
      ];
      allowedDomains = [
        "github.com"
        "api.github.com"
        "api.individual.githubcopilot.com"
        "copilot-proxy.githubusercontent.com"
        "origin-tracker.githubusercontent.com"
        "githubcopilot.com"
        "copilot-telemetry.githubusercontent.com"
        "collector.github.com"
        "default.exp-tas.com"
      ];
    };
  };
}
