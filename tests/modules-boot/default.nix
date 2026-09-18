# every module, on every implementation, booted
#
# tests/modules evaluates each module's units and asks whether they are coherent - no dangling
# edge, no readiness the backend cannot observe, no cycle. tests/modules-vm boots a handful of
# machines and asks whether particular daemons do their job. Between them sat the question
# neither answers: does a module's daemon actually come up, on a real machine, on this init?
#
# It is not implied by the unit graph being coherent. services.dhcpcd declared a readiness
# check which ran `dhcpcd -w`, and `dhcpcd -w` starts a dhcpcd when there is not one - so the
# probe raced the daemon it was meant to observe, won on runit and sinit, and left the unit
# restarting forever. Every assertion in tests/modules passed the whole time. It took a
# machine, and the only reason it was ever seen is that resolvconf happened to have one.
#
# So: one machine per module per implementation, which asserts exactly one thing - that the
# system still reaches the top of its trunk. That is a real question and a cheap one to ask.
# Every unit a module adds attaches to a trunk level, and a level waits for its dependants, so
# a daemon which never signals readiness stalls the trunk and the marker never appears. The
# failure mode this catches is precisely "enabled, and silently never came up".
#
# What it deliberately does not assert is behaviour. Whether the daemon serves, speaks its
# protocol or writes what it should is the module's own business, and where that matters it
# earns a hand-written test in tests/modules-vm rather than a line here.
{
  lib,
  pkgs,
  mkTest,
  ...
}:
let
  testLib = import ../lib { inherit lib pkgs; };
  coreLib = import ../providers/core/lib.nix { inherit pkgs lib; };

  backends = [
    "finit"
    "dinit"
    "runit"
    "s6-rc"
    "sinit"
    "openrc"
  ];

  # the same derivation of the enable option from the directory layout that tests/modules uses:
  # modules/services/foo is services.foo, modules/programs/bar is programs.bar
  modulesIn =
    kind:
    lib.filter (n: n != "README.md") (
      lib.attrNames (
        lib.filterAttrs (_: t: t == "directory") (builtins.readDir (../../modules + "/${kind}"))
      )
    );

  # a directory is named after its option nearly always, and where it is not this says so.
  # Without it the mismatch is silent: the option path simply does not exist, the module drops
  # out of the list, and nothing reports that it was never checked.
  optionName = {
    chronyd = "chrony";
  };

  enableOf = name: optionName.${name} or name;

  # a module with no `enable` at all is one a machine always has - coreutils, the shell -
  # or one shaped differently enough that turning it on is not a thing. There is nothing
  # here to boot for those.
  # whether a module has something to turn on.
  #
  # Usually that is `<kind>.<name>.enable`, declared by the module itself. A module which is an
  # alias for another has no options of its own though - mkAliasOptionModule renames the whole
  # subtree, so `services.lix-daemon` is one option standing for `services.nix-daemon` rather
  # than an attribute set with an `enable` inside it. Asking only for the `enable` misses those
  # entirely, which is a module silently never checked - and `services.lix-daemon.enable = true`
  # works perfectly well, forwarding to the module it renames.
  hasEnableAt =
    opts: kind: name:
    let
      path = [
        kind
        (enableOf name)
      ];
      here = lib.attrByPath path null opts;
    in
    if here == null then
      false
    else if here._type or null == "option" then
      true # an alias for a module which has one
    else
      here ? enable;

  hasEnable =
    kind: name:
    hasEnableAt (testLib.evalNode "machine" (machine "services" "getty" "finit")).options kind name;

  # modules which cannot be turned on without being told something first. The same list
  # tests/modules keeps, and for the same reason: a module which refuses to evaluate is a
  # thing that check reports, not something for a machine to discover by failing to boot.
  needsConfiguration = [
    "sshguard"
    "autologin"
    "postgresql"
    "nvidia-settings"
    "nvidia-persistenced"
    "nvidia-powerd"
    "keventd"
  ];

  # and modules which evaluate but cannot come up on a machine like this one, each with what it
  # is waiting for. A module here is not excused - it is documented, and the note is what tells
  # the next person whether the entry is still true.
  cannotBoot = {
    # VirtualBox has no aarch64 build, so on this machine the module cannot be evaluated
    # at all, let alone booted. Named here rather than left to the catch above, so that
    # the reason is written where somebody reads it.
    virtualbox = "an x86_64 host; there is no aarch64 build of VirtualBox";

    # incus puts minio on its unit's PATH, and nixpkgs marks minio insecure - so evaluating
    # this machine at all needs permittedInsecurePackages, which is a machine-wide loosening
    # of policy to boot one module, and not worth it
    incus = "nixpkgs.config.permittedInsecurePackages, for the minio on its PATH";
  };

  skipped = needsConfiguration ++ lib.attrNames cannotBoot;

  machine =
    kind: name: backend:
    { modules, ... }:
    {
      imports = lib.optional (backend != "finit") modules.${backend};

      config = lib.mkMerge [
        {
          providers.services.backend = backend;

          # `mkDefault`, because the module under test may be one of these. Turning getty on is
          # what the getty row does, and a flat `false` here would be a conflict rather than a
          # default to override.
          services.getty.enable = lib.mkDefault false;
          services.mdevd.enable = lib.mkDefault true;

          # a terminal, attached to nothing: what this test waits on is the trunk, and a prompt
          # is for looking at one which stalled. Not declared when getty is the module under
          # test - it provides its own, on the same tty, and two units for one terminal is a
          # conflict about the test rather than about the module.
          providers.ttys.devices = lib.mkIf (name != "getty") {
            tty1 = {
              description = "getty on /dev/tty1";
              requires = [ ];
            };
          };

          providers.services.tmpfiles.rules = [
            {
              path = coreLib.markerDir;
              type.directory.mode = "1777";
            }
          ];

          # the marker itself, at the top of the trunk. Reaching it means every level below was
          # reached, which means everything attached to those levels became ready.
          providers.services.units.booted = coreLib.bootedUnit;
        }

        (lib.setAttrByPath [ kind (enableOf name) "enable" ] true)
      ];
    };

  test = kind: name: backend: {
    name = "modules-boot.${name}-${backend}";
    nodes.machine = machine kind name backend;

    testScript = ''
      machine.start()

      # generous, and deliberately so: this is asking whether the trunk completes at all, not
      # how quickly. A module which is slow is not the failure being looked for; one which
      # never arrives is.
      machine.wait_until_succeeds("test -e ${coreLib.bootedMarker}", timeout=300)

      machine.shutdown()
    '';
  };

  # a module which cannot be instantiated on this machine at all - a package with no build for
  # this system, most often - is one failing check rather than the end of the run.
  # `--keep-going` keeps going through failed *builds*; an evaluation error is not one of
  # those, it stops everything, and in a row of 570 machines that means one unsupported
  # package hides every other result.
  attempt =
    kind: name: backend:
    let
      r = builtins.tryEval (mkTest (test kind name backend));
    in
    if r.success then
      r.value
    else
      pkgs.runCommand "check-${kind}-${name}-${backend}" { } ''
        echo "${kind}.${name} on ${backend}: cannot be evaluated on this system" >&2
        echo "  usually a package which does not build here - build it directly to see why" >&2
        exit 1
      '';

  row = kind: name: lib.recurseIntoAttrs (lib.genAttrs backends (backend: attempt kind name backend));

  rowsFor =
    kind:
    lib.recurseIntoAttrs (
      lib.listToAttrs (
        map (name: lib.nameValuePair name (row kind name)) (
          lib.filter (name: !(lib.elem name skipped) && hasEnable kind name) (modulesIn kind)
        )
      )
    );
in
{
  services = rowsFor "services";
  programs = rowsFor "programs";
}
