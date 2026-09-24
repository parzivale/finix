{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.programs.ssh;

  entries = lib.attrValues cfg.knownHosts;

  knownHostsText =
    lib.concatMapStringsSep "\n" (
      host:
      lib.optionalString host.certAuthority "@cert-authority "
      + lib.concatStringsSep "," host.hostNames
      + " "
      + (if host.publicKey != null then host.publicKey else lib.readFile host.publicKeyFile)
    ) entries
    + "\n";

  knownHostsFiles = [ "/etc/ssh/ssh_known_hosts" ] ++ map toString cfg.knownHostsFiles;

  # ssh_config(5) spells its values three ways: a bare word, a comma-separated list, and
  # yes/no. One renderer for all three, so `settings` can take any of them without a named
  # option per key.
  renderValue =
    value:
    if lib.isBool value then
      if value then "yes" else "no"
    else if lib.isList value then
      lib.concatStringsSep "," (map toString value)
    else
      toString value;

  settingsText = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (key: value: "  ${key} ${renderValue value}") (
      lib.filterAttrs (_: value: value != null) cfg.settings
    )
  );
in
{
  options.programs.ssh = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to install the ssh client and write the system-wide
        {file}`/etc/ssh/ssh_config` and {file}`/etc/ssh/ssh_known_hosts`.

        This is the client. The server is {option}`services.openssh.enable`.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openssh;
      defaultText = lib.literalExpression "pkgs.openssh";
      description = ''
        The package to use for `ssh`.
      '';
    };

    knownHosts = lib.mkOption {
      default = { };
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, config, ... }:
          {
            options = {
              certAuthority = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = ''
                  Whether this key is an ssh certificate authority rather than one host's key.
                '';
              };

              hostNames = lib.mkOption {
                type = with lib.types; listOf str;
                default = [ name ] ++ config.extraHostNames;
                defaultText = lib.literalExpression "[ name ] ++ config.extraHostNames";
                description = ''
                  The names and addresses this key is accepted for. The attribute's own name is
                  in here by default; setting this explicitly drops that, and
                  {option}`extraHostNames` adds to it without dropping it.
                '';
              };

              extraHostNames = lib.mkOption {
                type = with lib.types; listOf str;
                default = [ ];
                description = ''
                  Further names and addresses, added to the default {option}`hostNames`.
                  Ignored when that is set explicitly.
                '';
              };

              publicKey = lib.mkOption {
                type = with lib.types; nullOr str;
                default = null;
                example = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA...";
                description = ''
                  The key itself: a type and a key, with no host names in front of it -
                  `ssh-keyscan` prints them with, so the names have to come off.
                '';
              };

              publicKeyFile = lib.mkOption {
                type = with lib.types; nullOr path;
                default = null;
                description = ''
                  A file holding that same thing, read at build time. One key only; a host with
                  several wants an entry each, or {option}`programs.ssh.knownHostsFiles`.
                '';
              };
            };
          }
        )
      );
      description = ''
        The system-wide known hosts, written to {file}`/etc/ssh/ssh_known_hosts`.

        Knowing a host's key ahead of time is what makes the first connection to it meaningful:
        without it ssh asks, and a script answering that question is answering it blind.
      '';
      example = lib.literalExpression ''
        {
          "builder" = {
            extraHostNames = [ "builder.example.org" ];
            publicKeyFile = ./builder-host-key.pub;
          };
        }
      '';
    };

    knownHostsFiles = lib.mkOption {
      type = with lib.types; listOf path;
      default = [ ];
      description = ''
        Further known-hosts files, named in `GlobalKnownHostsFile` after
        {file}`/etc/ssh/ssh_known_hosts`. For a host with several keys, where
        {option}`knownHosts` takes one each.
      '';
    };

    settings = lib.mkOption {
      type =
        with lib.types;
        attrsOf (
          nullOr (oneOf [
            bool
            int
            str
            (listOf str)
          ])
        );
      default = { };
      example = {
        Ciphers = [
          "chacha20-poly1305@openssh.com"
          "aes256-gcm@openssh.com"
        ];
        ForwardX11 = false;
      };
      description = ''
        ssh_config(5) options, written into the `Host *` block. A bool becomes `yes`/`no`, a
        list becomes the comma-separated form those options take, and null drops the key.

        Per-host blocks go in {option}`extraConfig`, since a `Host` pattern is structure rather
        than a key and a value.
      '';
    };

    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = ''
        Lines placed at the top of {file}`/etc/ssh/ssh_config`, before the generated
        `Host *` block - which is what makes them override it. ssh takes the first value it
        finds for an option, so anything after that block cannot change it.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = lib.mapAttrsToList (name: host: {
      assertion = (host.publicKey == null) != (host.publicKeyFile == null);
      message = ''
        programs.ssh.knownHosts.${name} needs exactly one of `publicKey` and `publicKeyFile`.
      '';
    }) cfg.knownHosts;

    environment.systemPackages = [ cfg.package ];

    environment.etc."ssh/ssh_known_hosts".text = knownHostsText;

    environment.etc."ssh/ssh_config".text =
      lib.concatStringsSep "\n" (
        lib.optional (cfg.extraConfig != "") cfg.extraConfig
        ++ [
          "Host *"
          "  GlobalKnownHostsFile ${lib.concatStringsSep " " knownHostsFiles}"
        ]
        ++ lib.optional (settingsText != "") settingsText
      )
      + "\n";
  };
}
