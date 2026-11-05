# how services.wpa_supplicant runs, as providers.services units
#
# Separated from the module's own options and configuration so that what this module asks of
# the service contract is in one place, the same way a module implementing a `providers.*`
# contract keeps its implementation in a file named for it.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.wpa_supplicant;

  # each interface introduced by `-i` and closed by `-N` before the next, which is how one
  # process is told about several. nl80211 first, and wext for the drivers nl80211 has not
  # reached.
  interfaceArgs = lib.concatMapStringsSep " -N " (
    i: "-i ${i} -c ${cfg.configFile} -D nl80211,wext"
  ) cfg.interfaces;

  command = lib.concatStringsSep " " (
    [ (lib.getExe' cfg.package "wpa_supplicant") ]
    ++ lib.optional cfg.dbus "-u"
    ++ lib.optional cfg.debug "-dd"
    ++ lib.optional (cfg.interfaces != [ ]) interfaceArgs
  );
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.wpa_supplicant = {
      description = "wireless supplicant";

      # the bus and its socket gate are in the head tier, so `service/dbus/ready` is behind
      # this without being named
      requires = [ "basic" ];

      # read from the store path named in the command, so a changed configuration is already a
      # changed unit; this is for the reload below rather than for the restart
      reloadTriggers = lib.optional (cfg.interfaces != [ ]) cfg.configFile;

      type.service = {
        inherit command;

        # rereads the configuration of the interfaces it manages itself. Ones added over D-Bus
        # belong to whoever added them, and a HUP leaves them alone.
        reload = "${lib.getExe' pkgs.procps "pkill"} -HUP -x wpa_supplicant";

        # up once it owns its bus name, which is the moment a network manager can use it. A
        # manager started before then finds the name unowned, and with no activation file to
        # fall back on - see default.nix - has no wifi until the name appears.
        #
        # Bounded, like every other check: a supplicant that never reaches the bus has failed,
        # and saying so is better than holding everything that requires it.
        readiness = lib.mkIf cfg.dbus {
          waitFor.check.command = pkgs.writeShellScript "wpa_supplicant-ready" ''
            for _ in $(${lib.getExe' pkgs.coreutils "seq"} 100); do
              if ${lib.getExe' pkgs.dbus "dbus-send"} --system --print-reply \
                  --dest=org.freedesktop.DBus /org/freedesktop/DBus \
                  org.freedesktop.DBus.NameHasOwner string:fi.w1.wpa_supplicant1 2>/dev/null \
                  | ${lib.getExe' pkgs.gnugrep "grep"} -q 'boolean true'; then
                exit 0
              fi
              ${lib.getExe' pkgs.coreutils "sleep"} 0.1
            done

            echo "wpa_supplicant: fi.w1.wpa_supplicant1 not on the bus after 10s" >&2
            exit 1
          '';
        };
      };
    };
  };
}
