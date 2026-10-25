{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.programs.niri;

  # what niri publishes once it is up: the wayland socket it bound, which is the one thing the
  # session launcher cannot know in advance. niri takes whichever `wayland-N` is free through
  # smithay's `new_auto` and has no flag to force one, so it is found rather than chosen - and
  # finding none is what says niri is not ready yet.
  #
  # `*.*` excluded because the lock file beside each socket is `wayland-N.lock`.
  sessionEnv = pkgs.writeShellScript "niri-session-env" ''
    [ -n "''${XDG_RUNTIME_DIR:-}" ] || exit 1

    socket=$(
      cd "$XDG_RUNTIME_DIR" 2>/dev/null &&
        ${lib.getExe pkgs.findutils} . -maxdepth 1 -name 'wayland-*' -not -name '*.*' \
          -printf '%f\n' | ${lib.getExe' pkgs.coreutils "sort"} | ${lib.getExe' pkgs.coreutils "head"} -1
    )

    [ -n "$socket" ] || exit 1

    echo "WAYLAND_DISPLAY=$socket"
  '';

  # through the session launcher where there are user trees for it to start, so that a greeter
  # which offers this entry starts the whole session and not only the compositor. It needs no
  # `--user` - it is the same file for everyone - and no `dbus-run-session`, because the launcher
  # starts the bus. Without trees, the entry that was always here.
  exec =
    if config.providers.services.users != { } then
      lib.escapeShellArgs [
        "${config.providers.services.user.sessionLauncher}"
        "--log"
        "niri"
        "--session-env"
        "${sessionEnv}"
        "--"
        (lib.getExe cfg.package)
        "--session"
      ]
    else
      "${pkgs.dbus}/bin/dbus-run-session -- ${lib.getExe cfg.package} --session";

  sessionFile = pkgs.writeTextDir "share/wayland-sessions/niri.desktop" ''
    [Desktop Entry]
    Comment=A scrollable-tiling Wayland compositor
    DesktopNames=niri
    Exec=${exec}
    Name=Niri
    Type=Application
  '';

  # gardendevd needs libudev-garden; mdevd/keventd need libudev-zero
  udevApi =
    if config.services.gardendevd.enable then
      pkgs.libudev-garden
    else if config.services.mdevd.enable || config.services.keventd.enable then
      pkgs.libudev-zero
    else
      null;

  overrideAttrs = lib.optionalAttrs (udevApi != null) {
    eudev = udevApi;

    libinput = pkgs.libinput.override {
      udev = udevApi;
      wacomSupport = false;
    };

    # since we're recompiling go ahead and disable systemd
    withSystemd = false;
  };
in
{
  options.programs.niri = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [niri](${pkgs.niri.meta.homepage}).
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.niri.override overrideAttrs;
      defaultText = lib.literalExpression "pkgs.niri";
      description = ''
        The package to use for `niri`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      cfg.package

      # override wayland session with one that includes absolute paths + dbus-run-session invocation
      (lib.hiPrio sessionFile)
    ];

    # A compositor with no GL context is a compositor which does not start. nixos gets this
    # from niri-flake, whose module sets the same default, so a machine moving from there
    # would otherwise lose it silently: niri would build, install, and fail to open a display.
    #
    # mkDefault, because whether a machine wants a graphics stack is the machine's to say - a
    # niri driven entirely through the software renderer is unusual, not absurd.
    hardware.graphics.enable = lib.mkDefault true;
  };
}
