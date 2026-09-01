{ pkgs }:

pkgs.swiftPackages.stdenv.mkDerivation {
  pname = "llm-jail-vz";
  version = "1";
  src = ./.;

  strictDeps = true;
  nativeBuildInputs = [
    pkgs.darwin.sigtool
    pkgs.swift
  ];

  buildPhase = ''
    runHook preBuild
    swiftc -target arm64-apple-macosx13.0 \
      -O -o llm-jail-vz console-relay.swift main.swift
    runHook postBuild
  '';

  doCheck = true;

  checkPhase = ''
    runHook preCheck
    swiftc -target arm64-apple-macosx13.0 \
      -O -o console-relay-test console-relay.swift tests/main.swift
    ./console-relay-test
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 llm-jail-vz $out/bin/llm-jail-vz
    runHook postInstall
  '';

  postFixup = ''
    codesign --entitlements $src/llm-jail-vz.entitlements \
      -f -s - $out/bin/llm-jail-vz
  '';
}
