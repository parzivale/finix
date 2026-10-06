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

  # the agent's socket, spelled where nixos spells it: `%t/ssh-agent` there is
  # `$XDG_RUNTIME_DIR/ssh-agent` here, and it is the same path on disk either way. A fixed name
  # rather than ssh-agent's own default, which is a directory in /tmp named after the agent's
  # pid and so cannot be written down anywhere.
  agentSocket = "$XDG_RUNTIME_DIR/ssh-agent";

  agentFlags =
    lib.optionalString (cfg.agentTimeout != null) "-t ${cfg.agentTimeout} "
    + lib.optionalString (cfg.agentPKCS11Whitelist != null) "-P ${cfg.agentPKCS11Whitelist} ";

  # a script rather than a command line, for two reasons which both come from the contract.
  #
  # `type.service.command` is handed to the backend as written, and dinit - the only
  # implementation that can be a user's supervisor today - splits it on whitespace rather than
  # giving it to a shell. So `$XDG_RUNTIME_DIR` would not expand and `rm` could not be sequenced
  # before the exec. Both have to be inside something with a shebang.
  #
  # `-D` is the part nixos does not have. Its unit runs `ssh-agent -a %t/ssh-agent` with no
  # `-D`, which forks and lets the parent exit: systemd tolerates that because `Type=simple`
  # plus cgroup tracking keeps the forked child, and `SuccessExitStatus = "0 2"` stops it being
  # read as a crash. Every implementation here watches the main pid instead, so the same command
  # would be a service that exits immediately and is restarted for ever - which is the reason
  # `waitFor.pidfile` is refused against the thin backends. Foreground, and the supervision
  # means what it says.
  #
  # The `rm` is nixos' `ExecStartPre` and is not optional: a socket left behind by a previous
  # session is a file in the way, and `bind()` fails on it rather than replacing it.
  agentCommand = pkgs.writeShellScript "ssh-agent-start" ''
    socket="${agentSocket}"
    ${lib.getExe' pkgs.coreutils "rm"} -f "$socket"
    exec ${lib.getExe' cfg.package "ssh-agent"} -D ${agentFlags}-a "$socket"
  '';

  # ready when the socket accepts, not when the process exists.
  #
  # `waitFor.check` rather than `waitFor.socket`, which is the kind that means this: a readiness
  # path is passed as an argument and never sees a shell, and the path here contains
  # `$XDG_RUNTIME_DIR`, which is per-user and not known when this is evaluated. The check is a
  # command, so it can expand it.
  agentReady = pkgs.writeShellScript "ssh-agent-ready" ''
    socket="${agentSocket}"
    for _ in $(${lib.getExe' pkgs.coreutils "seq"} 1 100); do
      [ -S "$socket" ] && exit 0
      ${lib.getExe' pkgs.coreutils "sleep"} 0.05
    done
    exit 1
  '';

  # nixos says this with `ConditionUser = "!@system"` on a unit it emits for everybody; the
  # trees here are declared per user, so the same thing is said by choosing which users get one.
  agentUsers = lib.attrNames (lib.filterAttrs (_: u: u.isNormalUser) config.users.users);
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

    startAgent = lib.mkOption {
      type = lib.types.bool;
      default = false;
      example = true;
      description = ''
        Whether to run `ssh-agent` in each normal user's session.

        The agent listens on {file}`$XDG_RUNTIME_DIR/ssh-agent` and
        {env}`SSH_AUTH_SOCK` is exported into the session, so everything started by it -
        including a terminal which proxies the agent onward - finds the same one.

        One agent per session rather than per user, which is what this contract can express:
        the tree is started by the session and stops with it, so the keys do not outlive a
        logout. That is the behaviour wanted from an agent holding a hardware token.

        Independent of {option}`programs.ssh.enable`, which is about the client's
        configuration file; this is about a daemon.
      '';
    };

    agentTimeout = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
      example = "1h";
      description = ''
        How long the agent keeps a key before forgetting it, as `ssh-agent -t` takes it, or
        null to keep keys until the session ends.
      '';
    };

    agentPKCS11Whitelist = lib.mkOption {
      type = with lib.types; nullOr path;
      default = null;
      example = lib.literalExpression ''"''${pkgs.opensc}/lib/opensc-pkcs11.so"'';
      description = ''
        A pattern limiting which PKCS#11 or FIDO libraries `ssh-add -s` may load into the
        agent, as `ssh-agent -P` takes it. Null leaves ssh-agent's own default, which permits
        nothing but its compiled-in paths.

        Not needed for a FIDO token through `ssh-add -K`: that goes through the agent's
        built-in security-key support rather than a loaded provider.
      '';
    };

    askPassword = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
      example = lib.literalExpression "lib.getExe pkgs.lxqt.lxqt-openssh-askpass";
      description = ''
        A program which prompts for a passphrase or a token's PIN, exported as
        {env}`SSH_ASKPASS`, or null to leave it unset.

        Only reached when there is no terminal to ask on. ssh prompts on the tty whenever it
        has one - the test is `isatty(stdin)`, not whether a display is set - so somebody
        running `ssh-add` in a terminal never gets here, on X11 or Wayland or neither.

        What does get here is a prompt with stdin redirected: a unit, a hook, an editor's git
        integration, anything run without a controlling terminal. With this null such a prompt
        cannot be answered at all, because the openssh package ships no askpass of its own and
        the compiled-in default does not exist:

        ```
        ssh_askpass: exec(.../libexec/ssh-askpass): No such file or directory
        ```

        {env}`SSH_ASKPASS_REQUIRE` is the other half of this and is left to the environment:
        `force` uses the program even when there is a tty, `never` refuses it even when there
        is not.
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
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
    })

    (lib.mkIf cfg.startAgent {
      # asserted rather than worked around. A machine with no user supervisor has nowhere to put
      # a per-session daemon, and the alternatives are both worse than refusing: a system unit
      # running as the user would start at boot, outlive every session and hold keys across a
      # logout, and doing nothing at all would leave `startAgent = true` looking like it had
      # taken effect.
      assertions = [
        {
          assertion = config.providers.services.user.backend != null;
          message = ''
            programs.ssh.startAgent needs providers.services.user.backend, which names the
            implementation supervising a user's units - the agent is one of them.

            Set it to an implementation this configuration imports (dinit is the one that can
            run as a user today), or leave startAgent off and run ssh-agent by hand.
          '';
        }
      ];

      providers.services.users = lib.genAttrs agentUsers (_: {
        units.ssh-agent = {
          description = "ssh authentication agent";

          # nothing: the agent needs no part of the system to be up, and the default is the
          # first trunk level, which is a *system* unit and not something a user's tree can
          # wait for.
          requires = [ ];

          type.service = {
            command = toString agentCommand;
            readiness.waitFor.check.command = toString agentReady;
          };
        };

        # into the session, and only the session - which is the difference that makes a terminal
        # multiplexing an agent onward work.
        #
        # nixos puts this in `environment.extraInit`, guarded by `[ -z "$SSH_AUTH_SOCK" ]`,
        # because /etc/profile is also read by shells started *inside* a session which may
        # already have an agent of their own: wezterm with `ssh_domains` configured, for one,
        # exports its own proxy socket into every pane and forwards it to whatever
        # SSH_AUTH_SOCK it was itself started with. Overwriting that in the pane would bypass
        # the proxy.
        #
        # Here it needs no guard, because `sessionVariables` is exported once by the session
        # launcher rather than by every shell. The session gets this agent, and a terminal which
        # proxies it inherits it and has something real to forward to.
        sessionVariables.SSH_AUTH_SOCK = agentSocket;
      });
    })

    # independent of `startAgent`, as it is on nixos: a passphrase prompt is wanted by `ssh` and
    # `ssh-add` whether or not anything is supervising an agent. `environment.variables` rather
    # than a session variable for the same reason - it is not a property of being logged in
    # graphically, only of what to run when ssh decides to ask.
    (lib.mkIf (cfg.askPassword != null) {
      environment.variables.SSH_ASKPASS = cfg.askPassword;
    })
  ];
}
