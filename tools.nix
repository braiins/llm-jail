{
  claude = {
    guestModule = ./guests/claude.nix;
    defaults = {
      mem = 4096; vcpu = 2;
      configDirName = ".claude";
      configEnvVar = "CLAUDE_CONFIG_DIR";
      allowedDomains = [
        "api.anthropic.com"
        # OAuth login flows (claude.ai and Console accounts) - needed for the
        # first-run login inside the jail
        "claude.ai"
        "platform.claude.com"
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
      configEnvVar = "CODEX_HOME";
      allowedDomains = [
        "api.openai.com"
        # OAuth issuer for in-jail login (token exchange)
        "auth.openai.com"
        "chatgpt.com"
        "sentry.io"
      ];
    };
  };
  shell = {
    guestModule = ./guests/shell.nix;
    defaults = {
      mem = 2048; vcpu = 2;
      # No config dir - the debug shell keeps no persistent state.
      # No domains whitelisted by default - debug shell runs offline unless
      # the user opts in with --allow-domain or --no-net-filter.
      allowedDomains = [ ];
    };
  };
  copilot = {
    guestModule = ./guests/copilot.nix;
    defaults = {
      mem = 4096; vcpu = 2;
      configDirName = ".copilot";
      configEnvVar = "COPILOT_HOME";
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
