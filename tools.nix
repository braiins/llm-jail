{
  claude = {
    guestModule = ./guests/claude.nix;
    defaults = {
      mem = 4096;
      vcpu = 2;
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
      mem = 4096;
      vcpu = 2;
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
  opencode = {
    guestModule = ./guests/opencode.nix;
    defaults = {
      mem = 4096;
      vcpu = 2;
      configDirName = ".opencode";
      # opencode has no dedicated state-relocation variable; it derives all
      # its paths from XDG base dirs, so auth.json and the session DB land in
      # <mount>/opencode/. The launcher wrapper (guests/opencode.nix) keeps
      # the config and cache dirs inside the same mount.
      configEnvVar = "XDG_DATA_HOME";
      allowedDomains = [
        # opencode infrastructure
        "models.dev" # model catalog, fetched at startup
        "registry.npmjs.org" # provider packages, installed on first use
        # providers (subdomains are matched automatically); account-specific
        # endpoints (Bedrock, Azure, Vertex) need --allow-domain
        "api.anthropic.com"
        "claude.ai" # OAuth authorize for in-jail login
        "console.anthropic.com" # OAuth token exchange and refresh
        "api.openai.com"
        "auth.openai.com"
        "chatgpt.com"
        "generativelanguage.googleapis.com"
        "github.com" # Copilot device-flow login
        "api.github.com"
        "api.githubcopilot.com"
        "openrouter.ai"
        "api.deepseek.com"
        "api.mistral.ai"
        "api.x.ai"
        "api.groq.com"
        "api.cerebras.ai"
        "api.novita.ai"
      ];
    };
  };
  shell = {
    guestModule = ./guests/shell.nix;
    defaults = {
      mem = 2048;
      vcpu = 2;
      # Shell state dir mounted to ~/.shell, ZDOTDIR specifies zsh config file location,
      # no equivalent option exists for bash :'(
      configDirName = ".shell";
      configEnvVar = "ZDOTDIR";
      # No domains whitelisted by default - debug shell runs offline unless
      # the user opts in with --allow-domain or --no-net-filter.
      allowedDomains = [ ];
    };
  };
  copilot = {
    guestModule = ./guests/copilot.nix;
    defaults = {
      mem = 4096;
      vcpu = 2;
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
