{
  config,
  options,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nixpkgs;
  opt = options.nixpkgs;

  isConfig = x: builtins.isAttrs x || lib.isFunction x;

  optCall = f: x: if lib.isFunction f then f x else f;

  mergeConfig =
    lhs_: rhs_:
    let
      lhs = optCall lhs_ { inherit lib pkgs; };
      rhs = optCall rhs_ { inherit lib pkgs; };
    in
    lib.recursiveUpdate lhs rhs
    // lib.optionalAttrs (lhs ? packageOverrides) {
      packageOverrides =
        pkgs:
        optCall lhs.packageOverrides pkgs // optCall (lib.attrByPath [ "packageOverrides" ] { } rhs) pkgs;
    };

  configType = lib.mkOptionType {
    name = "nixpkgs-config";
    description = "nixpkgs config";
    check = x: isConfig x;
    merge = _args: lib.foldr (def: mergeConfig def.value) { };
  };

  overlayType = lib.mkOptionType {
    name = "nixpkgs-overlay";
    description = "nixpkgs overlay";
    check = lib.isFunction;
    merge = lib.mergeOneOption;
  };

  pkgsType = lib.types.pkgs // {
    description = "An evaluation of Nixpkgs; the top level attribute set of packages";
  };

  # A package set this module built, from `source` and the declared platforms.
  constructedPkgs = import cfg.source {
    inherit (cfg) config overlays;
    localSystem = cfg.buildPlatform;
    crossSystem = cfg.hostPlatform;
  };

  # A package set handed in whole takes precedence, and can only be extended:
  # its `config` and its platform were fixed when whoever made it imported
  # nixpkgs, so the options describing those are ignored rather than silently
  # half-applied.
  finalPkgs =
    if opt.pkgs.isDefined then
      cfg.pkgs.appendOverlays cfg.overlays
    else if opt.source.isDefined && opt.hostPlatform.isDefined then
      constructedPkgs
    else
      # Not an assertion: `pkgs` is forced long before assertions are collected,
      # so the failure has to speak for itself here or it arrives as a bare
      # "option was accessed but has no value defined".
      throw ''
        This machine has no package set. Either hand one in:

          nixpkgs.pkgs = import inputs.nixpkgs { system = "x86_64-linux"; };

        or say what to build one from:

          nixpkgs.source = inputs.nixpkgs;
          nixpkgs.hostPlatform = "x86_64-linux";
      '';
in
{
  options.nixpkgs = {
    pkgs = lib.mkOption {
      type = pkgsType;
      example = lib.literalExpression "import <nixpkgs> { system = \"x86_64-linux\"; }";
      description = ''
        A package set to use as-is, instead of one built here from
        {option}`nixpkgs.source` and {option}`nixpkgs.hostPlatform`.

        Setting this makes {option}`nixpkgs.config`, {option}`nixpkgs.hostPlatform`
        and {option}`nixpkgs.buildPlatform` inert: they describe how to build a
        package set, and this one is already built. {option}`nixpkgs.overlays`
        still apply, because a built set can be extended.
      '';
    };

    source = lib.mkOption {
      type = lib.types.path;
      example = lib.literalExpression "inputs.nixpkgs";
      description = ''
        The nixpkgs tree to build {option}`nixpkgs.pkgs` from.

        NixOS reads the tree it is itself part of; finix is not part of one and
        pins none, so whoever evaluates a machine says which nixpkgs it is
        evaluated against. Needed only when {option}`nixpkgs.pkgs` is not set.
      '';
    };

    config = lib.mkOption {
      default = { };
      example = {
        allowBroken = true;
        allowUnfree = true;
      };
      type = configType;
      description = ''
        The configuration of the Nix Packages collection - what
        {file}`~/.config/nixpkgs/config.nix` would hold for a user.

        Ignored when {option}`nixpkgs.pkgs` is set, because a built package set
        already has one.
      '';
    };

    overlays = lib.mkOption {
      default = [ ];
      example = lib.literalExpression ''
        [
          (final: prev: {
            openssh = prev.openssh.override { hpnSupport = true; };
          })
        ]
      '';
      type = lib.types.listOf overlayType;
      description = ''
        Overlays to apply to the package set every module sees as `pkgs`.

        A module needing a package nixpkgs does not have - or a different build
        of one it does - says so here, rather than the caller having to know
        what every module on the machine will want. Unlike the options above
        these apply either way: to a set built here, and to one handed in
        through {option}`nixpkgs.pkgs`, where they are appended after whatever
        it already carries.
      '';
    };

    hostPlatform = lib.mkOption {
      type = lib.types.either lib.types.str lib.types.attrs;
      example = {
        system = "aarch64-linux";
      };
      # Elaborated so that everything reading this sees every field, the same
      # way `pkgs.stdenv.hostPlatform` has them.
      apply = lib.systems.elaborate;
      description = ''
        The platform this machine runs on.

        A fact about the machine rather than about the package set, which is
        what lets it be checked: when a package set is also handed in, an
        assertion compares the two rather than trusting that whoever built it
        chose the same answer.

        To cross-compile, set {option}`nixpkgs.buildPlatform` as well.
      '';
    };

    buildPlatform = lib.mkOption {
      type = lib.types.either lib.types.str lib.types.attrs;
      default = cfg.hostPlatform;
      example = {
        system = "x86_64-linux";
      };
      apply =
        inputBuildPlatform:
        let
          elaborated = lib.systems.elaborate inputBuildPlatform;
        in
        if lib.systems.equals elaborated cfg.hostPlatform then
          # identical, so that `==` on the two works
          cfg.hostPlatform
        else
          elaborated;
      defaultText = lib.literalExpression "config.nixpkgs.hostPlatform";
      description = ''
        The platform this machine is built on. Defaults to building where it
        runs; setting it to something else cross-compiles.

        Ignored when {option}`nixpkgs.pkgs` is set.
      '';
    };
  };

  config = {
    _module.args = {
      pkgs = finalPkgs;
    };

    assertions = [
      {
        assertion = opt.pkgs.isDefined || opt.source.isDefined;
        message = ''
          Neither `nixpkgs.pkgs` nor `nixpkgs.source` is set, so this machine
          has no package set: nothing to hand in, and nothing to build one
          from. Set `nixpkgs.source` to a nixpkgs tree and
          `nixpkgs.hostPlatform` to what this machine is, or set
          `nixpkgs.pkgs` to a package set built elsewhere.
        '';
      }

      {
        assertion = opt.pkgs.isDefined || opt.hostPlatform.isDefined;
        message = ''
          `nixpkgs.hostPlatform` is not set, so there is nothing to build
          `nixpkgs.source` for. Say what this machine is - `hostPlatform =
          "x86_64-linux"` - or hand in a package set through `nixpkgs.pkgs`.
        '';
      }

      {
        # The one check the old shape could not make: nineteen modules branch on
        # `pkgs.stdenv.hostPlatform`, and with a handed-in set nothing confirmed
        # it was built for the machine the rest of the configuration describes.
        assertion =
          opt.pkgs.isDefined
          -> opt.hostPlatform.isDefined
          -> cfg.hostPlatform.system == finalPkgs.stdenv.hostPlatform.system;
        message = ''
          `nixpkgs.hostPlatform` says this machine is
          ${cfg.hostPlatform.system}, but the package set given as
          `nixpkgs.pkgs` was built for
          ${finalPkgs.stdenv.hostPlatform.system}.

          Set one to match the other, or drop `nixpkgs.hostPlatform` and let
          the package set speak for itself.
        '';
      }
    ];
  };
}
