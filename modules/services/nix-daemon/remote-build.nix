# the machines nix may send builds to, as /etc/nix/machines
#
# Separated from the module's own options the way providers.services.nix is: this is one
# coherent thing the daemon can be told, and it is a file of its own rather than a nix.conf
# setting, so it is written in a file of its own here.
{
  config,
  lib,
  ...
}:
let
  cfg = config.services.nix-daemon;

  # The format /etc/nix/machines is read in: nine whitespace-separated fields per line, `-`
  # standing in for an unset one. Order is the format's, not ours - see the `builders` setting
  # in {manpage}`nix.conf(5)`.
  line =
    machine:
    lib.concatStringsSep " " [
      "${lib.optionalString (machine.protocol != null) "${machine.protocol}://"}${
        lib.optionalString (machine.sshUser != null) "${machine.sshUser}@"
      }${machine.hostName}"

      (
        if machine.system != null then
          machine.system
        else if machine.systems != [ ] then
          lib.concatStringsSep "," machine.systems
        else
          "-"
      )

      (if machine.sshKey != null then machine.sshKey else "-")
      (toString machine.maxJobs)
      (toString machine.speedFactor)

      # mandatory features are supported features too, so a machine does not have to say one
      # of them twice
      (
        let
          features = machine.supportedFeatures ++ machine.mandatoryFeatures;
        in
        if features == [ ] then "-" else lib.concatStringsSep "," features
      )

      (
        if machine.mandatoryFeatures == [ ] then "-" else lib.concatStringsSep "," machine.mandatoryFeatures
      )

      # the ninth field, which nix has read since 2.4 and lix has always read
      (if machine.publicHostKey != null then machine.publicHostKey else "-")
    ];
in
{
  options.services.nix-daemon = {
    buildMachines = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            hostName = lib.mkOption {
              type = lib.types.str;
              example = "nixbuilder.example.org";
              description = ''
                The hostname of the build machine.
              '';
            };

            protocol = lib.mkOption {
              type = lib.types.enum [
                null
                "ssh"
                "ssh-ng"
              ];
              default = "ssh";
              example = "ssh-ng";
              description = ''
                The protocol used to talk to the build machine. `ssh-ng` where both ends
                support it. `null` for a builder named without one, which is how the special
                localhost builder is written.
              '';
            };

            system = lib.mkOption {
              type = with lib.types; nullOr str;
              default = null;
              example = "x86_64-linux";
              description = ''
                The system type this machine can build for. Either this or
                {option}`systems` must be set; this one wins if both are.
              '';
            };

            systems = lib.mkOption {
              type = with lib.types; listOf str;
              default = [ ];
              example = [
                "x86_64-linux"
                "aarch64-linux"
              ];
              description = ''
                The system types this machine can build for. Either this or {option}`system`
                must be set.
              '';
            };

            sshUser = lib.mkOption {
              type = with lib.types; nullOr str;
              default = null;
              example = "builder";
              description = ''
                The user to log in as. That user must be able to run nix commands
                non-interactively, and must be able to build - so it belongs in
                {option}`services.nix-daemon.settings.trusted-users` on the far side.
              '';
            };

            sshKey = lib.mkOption {
              type = with lib.types; nullOr str;
              default = null;
              example = "/root/.ssh/id_buildhost_builduser";
              description = ''
                The private key to authenticate with, which must have no passphrase. When
                null, whoever is building - root - needs an ssh configuration that logs in
                non-interactively by itself.

                A path on the local filesystem, not in the store: the store is world-readable.
              '';
            };

            maxJobs = lib.mkOption {
              type = lib.types.int;
              default = 1;
              description = ''
                How many jobs this machine takes at once. The machine enforces its own limit
                regardless; saying it here is what lets a scheduler distribute sensibly
                without work-stealing.
              '';
            };

            speedFactor = lib.mkOption {
              type = lib.types.int;
              default = 1;
              description = ''
                How fast this machine is relative to the others. An arbitrary integer, higher
                being faster.
              '';
            };

            mandatoryFeatures = lib.mkOption {
              type = with lib.types; listOf str;
              default = [ ];
              example = [ "big-parallel" ];
              description = ''
                Features this machine is only used for. A derivation not requiring all of
                them goes elsewhere.
              '';
            };

            supportedFeatures = lib.mkOption {
              type = with lib.types; listOf str;
              default = [ ];
              example = [
                "kvm"
                "big-parallel"
              ];
              description = ''
                Features this machine can provide. A derivation requiring one that is not
                here goes elsewhere.
              '';
            };

            publicHostKey = lib.mkOption {
              type = with lib.types; nullOr str;
              default = null;
              description = ''
                This machine's base64-encoded public host key, as
                `base64 -w0 /etc/ssh/ssh_host_ed25519_key.pub` prints it. When null, ssh uses
                its own known-hosts file - see {option}`programs.ssh.knownHosts`.
              '';
            };
          };
        }
      );
      default = [ ];
      description = ''
        The machines builds may be sent to, when {option}`distributedBuilds` is on. nix copies
        a derivation's inputs to the machine's store over ssh, builds there, and copies the
        outputs back.
      '';
    };

    distributedBuilds = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to send builds to the machines in {option}`buildMachines`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions =
      let
        unnamed = m: m.system == null && m.systems == [ ];
        bad = lib.filter unnamed cfg.buildMachines;
      in
      [
        {
          assertion = bad == [ ];
          message = ''
            Every build machine needs a system type, through `system` or `systems`. These have
            neither: ${lib.concatStringsSep ", " (map (m: m.hostName) bad)}
          '';
        }
      ];

    # Written whenever there are machines, and read or not according to `builders` below -
    # which is what makes `distributedBuilds = false` a switch rather than a rewrite.
    environment.etc."nix/machines" = lib.mkIf (cfg.buildMachines != [ ]) {
      text = lib.concatMapStrings (m: line m + "\n") cfg.buildMachines;
    };

    # `builders` defaults to `@/etc/nix/machines` in nix itself, so the file being there is
    # already enough to use it. Turning distribution off therefore means clearing the setting,
    # not clearing the file.
    services.nix-daemon.settings = lib.mkIf (!cfg.distributedBuilds) { builders = null; };
  };
}
