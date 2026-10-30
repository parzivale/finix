{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.finit;
in
{
  imports = [
    ./initrd.nix
    ./mount.nix
    ./options.nix
    ./providers.services.nix
  ];

  config = {
    assertions = [
      {
        assertion = lib.versionAtLeast config.finit.package.version "5.0";
        message = "finit version must be at least 5.0";
      }
    ];

    finit.settings = lib.mkMerge [
      {
        inherit (cfg) readiness runlevel;
      }
      (lib.mkIf (cfg.environment != { }) { inherit (cfg) environment; })
      (lib.mkIf (cfg.cgroups != { }) { cgroup = cfg.cgroups; })
      (lib.mkIf (cfg.rlimits != { }) { rlimit = cfg.rlimits; })
    ];

    # TODO: decide a reasonable default here... user can override if needed
    finit.path = [
      config.programs.coreutils.package
      pkgs.findutils
      pkgs.gnugrep
      pkgs.gnused
      cfg.package

      # required by finit on shutdown
      pkgs.util-linux.mount

      # for finit log rotation
      pkgs.gzip
    ];

    finit.environment = lib.mkIf (cfg.path != [ ]) {
      PATH = lib.makeBinPath cfg.path;
    };

    environment.systemPackages = [
      cfg.package
    ];

    finit.tmpfiles.rules = [
      "d /etc/finit.d/enabled 0755"
    ];

    # what to do when ctrl-alt-del is pressed: the kernel sends SIGINT to PID 1, and finit
    # turns that into the `sys/key/ctrlaltdel` condition.
    #
    # finit's, and it lives here rather than in modules/boot because there is no portable
    # version of it - it is not a unit, it is what an init does with a signal, and each of the
    # others has its own answer (runit runs /etc/runit/ctrlaltdel, dinit and s6-linux-init
    # have their own handlers). Those are not wired up yet, so on any other backend the key
    # combination currently does whatever that init does by default.
    finit.tasks.ctrl-alt-del = {
      description = "rebooting system";
      runlevels = "12345789";
      conditions = "sys/key/ctrlaltdel";
      command = "${cfg.package}/bin/initctl reboot";
    };

    system.switch.inhibitors.finit-format = "libconfuse";
  };
}
