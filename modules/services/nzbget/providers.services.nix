# how services.nzbget runs, as providers.services units
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
  cfg = config.services.nzbget;

  logDir = "/var/log/nzbget";
  configFile = "${cfg.stateDir}/nzbget.conf";
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.nzbget =
      let
        configOpts = lib.concatStringsSep " " (
          lib.mapAttrsToList (name: value: "-o ${name}=${lib.escapeShellArg (toStr value)}") cfg.settings
        );
        toStr =
          v:
          if v == true then
            "yes"
          else if v == false then
            "no"
          else if lib.isInt v then
            toString v
          else
            v;

        script = pkgs.writeShellScript "nzbget.sh" ''
          exec ${lib.getExe cfg.package} --configfile ${configFile} ${configOpts} "$@"
        '';
      in
      {
        inherit (cfg) user group;

        description = "nzbget daemon";
        requires = [ "basic" ];

        # `pre` was finit's own start action, and `stop`/`reload` its own verbs - none of which
        # the contract models. The seeding `pre` did is folded into the command, which is the
        # one place every implementation runs: it has to happen before the server starts and
        # nothing else waits on it, so it needs no unit of its own.
        type.service.command = pkgs.writeShellScript "nzbget-server" ''
          if [ ! -f ${configFile} ]; then
            ${lib.getExe' config.programs.coreutils "install"} -o ${cfg.user} -g ${cfg.group} -m 0700 ${cfg.package}/share/nzbget/nzbget.conf ${configFile}
          fi

          exec ${script} --server
        '';
      };

    providers.services.tmpfiles.rules = [
      {
        type = "directory";
        path = logDir;
        mode = "0750";
        inherit (cfg) user group;
      }
    ]
    ++ lib.optional (cfg.stateDir == "/var/lib/nzbget") {
      type = "directory";
      path = cfg.stateDir;
      mode = "0750";
      inherit (cfg) user group;
    };
  };
}
