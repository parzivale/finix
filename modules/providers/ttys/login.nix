# the login prompt an implementation falls back to when a device is claimed with no command of
# its own.
#
# A function file rather than a module, like readiness.nix and shutdown.nix beside it: both
# implementations need the same command and neither owns it.
{
  pkgs,
  lib,
}:
let
  # agetty's compiled-in default login program is /bin/login, and finix has no /bin at all - so
  # without this the prompt never appears and the unit just respawns forever against a missing
  # file
  loginProgram = "/run/current-system/sw/bin/login";

  agetty = pkgs.util-linux // {
    meta = pkgs.util-linux.meta // {
      mainProgram = "agetty";
    };
  };
in
{
  # the device is the program's own argument: it opens the terminal, claims the session and
  # sets it up. That is true of every login prompt worth running - agetty, and the `agetty -nil
  # <greeter>` a display manager wants - so an implementation never has to wire up a terminal
  # itself, and the same command works whether it is supervised as a service or handed to an
  # init which knows what a tty is.
  commandFor =
    {
      package ? null,
      extraArgs ? [ ],
      device,
    }:
    lib.concatStringsSep " " (
      [
        (lib.getExe (if package != null then package else agetty))
        "--login-program"
        loginProgram
        "--noclear"
      ]
      ++ extraArgs
      ++ [
        device
        "linux"
      ]
    );
}
