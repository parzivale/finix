{
  pkgs,
  lib,
  backend,
  ...
}:
let
  coreLib = import ../providers/core/lib.nix { inherit pkgs lib; };
in
{
  name = "modules.micolash-${backend}";

  nodes.machine =
    { modules, ... }:
    {
      imports =
        with modules;
        [
          gnome-keyring
          niri
          pipewire
          sudo
          xwayland-satellite
          chronyd
          iwd
          ly
          polkit
        ]
        ++ [ (import ./base.nix { inherit backend; }) ];

      finit.runlevel = 3;

      # their finit, because keventd asserts 5.0 and nixpkgs has 4.17. It is also the reason
      # keventd is skipped by tests/modules, so this is the first time it is booted at all.
      finit.package = pkgs.finit.overrideAttrs (o: {
        version = "5.0";
        src = pkgs.fetchFromGitHub {
          owner = "finit-project";
          repo = "finit";
          rev = "ad8ed05d64a4e274e39ac2d061fe8c3aa8a87c22";
          sha256 = "sha256-SJTnrcgRx/M07pOQAnm+LeiXSq9YGCON2yHLaKCMyJw=";
        };
        buildInputs = o.buildInputs ++ [ pkgs.util-linuxMinimal.dev ];
      });

      services.keventd.enable = true;
      services.mdevd.enable = lib.mkForce false;

      services.sysklogd.enable = true;
      services.dbus.enable = true;
      services.seatd.enable = true;
      services.dhcpcd.enable = true;
      services.chrony.enable = true;
      services.iwd.enable = true;
      services.ly.enable = true;
      services.polkit.enable = true;

      programs.niri.enable = true;
      programs.pipewire.enable = true;
      programs.xwayland-satellite.enable = true;
      programs.gnome-keyring.enable = true;

      providers.services.units.booted = coreLib.bootedUnit;
      providers.services.tmpfiles.rules = lib.mkMerge [
        [
          {
            type = "directory";
            path = coreLib.markerDir;
            mode = "1777";
          }
        ]
        # slow tmpfiles-setup down, so that the runlevel switch lands while it is still running
        (lib.mkOrder 600 (
          lib.genList (i: {
            type = "directory";
            path = "/run/ballast/${toString i}";
          }) 4000
        ))
      ];
    };

  testScript = ''
    machine.start()
    machine.wait_until_succeeds("test -e ${coreLib.bootedMarker}", timeout=120)
    machine.succeed("cat /run/tmpfiles-setup.log >&2")
    machine.shutdown()
  '';
}
