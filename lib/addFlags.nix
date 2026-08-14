package: allFlags: apply:
let
  applyFlags =
    pkg: consumed:
    let
      leftover = removeAttrs allFlags (builtins.attrNames consumed);
    in
    pkg.overrideAttrs (o: {
      passthru =
        (o.passthru or { })
        // (builtins.mapAttrs (key: value: recursion (consumed // { ${key} = value; })) leftover);
    });
  recursion =
    consumed:
    let
      applied = apply package consumed;
    in
    if consumed != allFlags then applyFlags applied consumed else applied;
in
applyFlags package { }
