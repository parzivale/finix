# running the system's activation script, as part of the services contract
#
# /etc is not a filesystem on a finix machine, it is a symlink farm the activation script
# builds. Until that has run there is no /etc/dinit.d, no /etc/finit.conf and no passwd - so
# every init has to run it before reading its own configuration, and an init which does not
# boots into a machine with nothing in it.
#
# finit does this with finix-setup, a C plugin, from PLUGIN_INIT so that it happens before
# finit parses anything. Nothing about the job needs a plugin though, so this is the same work
# as a script for the inits which have no plugin mechanism to put it in.
#
# The awkward part is finding the closure. The obvious spelling - refer to
# config.system.topLevel - is a cycle: the toplevel contains boot.init, boot.init is the
# backend's initExecutable, and the wrapper would be referring to the thing it is part of. So
# the path is discovered at runtime instead, from the kernel's own init= parameter, which
# points into the closure by construction. finix-setup reads PID 1's /proc/self/cmdline for
# the same reason.
{
  config,
  pkgs,
  lib,
  ...
}:
{
  options.providers.services.activationScript = lib.mkOption {
    type = lib.types.path;
    internal = true;
    readOnly = true;

    description = ''
      A program which activates the booted system configuration: it runs the closure's
      `activate` script and puts the `/run/current-system` and `/run/booted-system` symlinks in
      place.

      An implementation which is PID 1 must run this before reading its own configuration,
      because its configuration is one of the things activation puts in `/etc`. finit is the
      exception: it does the same work from the finix-setup plugin, which runs earlier than
      anything this could be attached to.

      Owned by the contract rather than written once per backend - the job is the same
      whichever init is doing it, and getting it subtly wrong in three places is how three
      machines end up differing in ways nobody meant them to.
    '';
  };

  config.providers.services.activationScript = pkgs.writeShellScript "finix-activate" ''
    export PATH=${lib.makeBinPath [ pkgs.coreutils ]}:$PATH

    # the kernel was told init=<closure>/init, so the closure is that path's directory. This
    # cannot be a Nix reference: the closure contains the init being run, so naming it here
    # would be a cycle.
    sys=
    for param in $(cat /proc/cmdline); do
      case "$param" in
        init=*) sys="''${param#init=}" ;;
      esac
    done

    if [ -z "$sys" ]; then
      echo "finix-activate: no init= on the kernel command line, cannot find the system" >&2
      exit 1
    fi

    sys=$(dirname "$sys")

    if [ ! -x "$sys/activate" ]; then
      echo "finix-activate: $sys/activate is missing or not executable" >&2
      exit 1
    fi

    "$sys/activate"

    # after activation, so that /run exists to put them in
    ln -sfn "$sys" /run/booted-system
    ln -sfn "$sys" /run/current-system
  '';
}
