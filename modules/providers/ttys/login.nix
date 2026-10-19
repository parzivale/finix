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
  # a getty's compiled-in default login program is /bin/login, and finix has no /bin at all - so
  # without this the prompt never appears and the unit just respawns forever against a missing
  # file
  loginProgram = "/run/current-system/sw/bin/login";

  agetty = pkgs.util-linux // {
    meta = pkgs.util-linux.meta // {
      mainProgram = "agetty";
    };
  };

  # how each getty wants to be invoked, keyed by name so a configuration can say
  # `args = "busybox"` rather than write the function out.
  #
  # The arguments are the getty's business and not the contract's. This used to be agetty's
  # flags written into `commandFor` for every package, so a busybox `getty` was handed
  # `--login-program`, refused it, and respawned forever - with nothing on the console, because
  # the only thing which would have drawn there was the prompt that never started.
  #
  # Each takes the same set: the device, the login program, an optional user to log in without
  # a prompt, and the configuration's extra arguments - placed by the getty, because where
  # options may go is part of its syntax (busybox's must precede the positional baud rate).
  args = {
    agetty =
      {
        device,
        login,
        autologin ? null,
        extraArgs ? [ ],
      }:
      [
        "--login-program"
        login
        "--noclear"
      ]
      # `--login-pause` waits for a keypress before handing the terminal over. With no prompt
      # to read, that is the only thing which makes whatever the boot left on the screen
      # readable.
      ++ lib.optionals (autologin != null) [
        "--autologin"
        autologin
        "--login-pause"
      ]
      ++ extraArgs
      ++ [
        device
        "linux"
      ];

    # `getty [OPTIONS] BAUD_RATE[,BAUD_RATE]... TTY [TERMTYPE]`. Short options only, no
    # `--noclear` because it does not clear in the first place, and a baud rate which is not
    # optional: `0` leaves the line's rate as it is.
    busybox =
      {
        device,
        login,
        autologin ? null,
        extraArgs ? [ ],
      }:
      if autologin != null then
        throw "providers.ttys: busybox getty has no autologin; use agetty for autologin on ${device}"
      else
        [
          "-l"
          login
        ]
        ++ extraArgs
        ++ [
          "0"
          device
          "linux"
        ];
  };

  # named apart because `commandFor` takes an `args` of its own, which shadows the set above
  agettyArgs = args.agetty;
in
{
  inherit args;

  # the device is the program's own argument: it opens the terminal, claims the session and
  # sets it up. That is true of every login prompt worth running - agetty, and the `agetty -nil
  # <greeter>` a display manager wants - so an implementation never has to wire up a terminal
  # itself, and the same command works whether it is supervised as a service or handed to an
  # init which knows what a tty is.
  commandFor =
    {
      package ? null,
      args ? null,
      extraArgs ? [ ],
      autologin ? null,
      device,
    }:
    let
      args' = if args != null then args else agettyArgs;
    in
    lib.concatStringsSep " " (
      [ (lib.getExe (if package != null then package else agetty)) ]
      ++ args' {
        inherit device extraArgs autologin;
        login = loginProgram;
      }
    );
}
