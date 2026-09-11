# runnable graphical VMs, one per services backend
#
# The test suite boots these same inits, but headless and driven by a python script - which
# proves the graph is right and tells you nothing about what the machine is like to sit in
# front of. These are for that: a window, a login prompt, and a shell.
#
#   nix-build vms -A dinit && ./result/bin/run-dinit-vm
#
# Each is the same configuration bar one line, `providers.services.backend`, which is the
# point - selecting it picks the supervisor and PID 1 together, and nothing else in here
# mentions an init.
#
# The store is shared from the host over 9p and the root is a tmpfs, so there is no disk image
# to build or keep in step: the VM is rebuilt from the store every boot and forgets everything
# when it stops.
{
  pkgs ?
    let
      sources = import ../lon.nix;
    in
    import sources.nixpkgs { },
}:
let
  inherit (pkgs) lib;

  finixModules = import ../modules;

  inherit (pkgs.stdenv.hostPlatform) isx86 isAarch;

  # the same split the test harness makes: x86 has an 8250 at ttyS0, aarch64's virt machine has
  # a PL011 at ttyAMA0. Naming the wrong one is silent - the kernel logs into a device which is
  # not there, and the terminal stays empty however badly the boot is going.
  serialDevice =
    if isx86 then
      "ttyS0"
    else if isAarch then
      "ttyAMA0"
    else
      throw "unknown serial device for ${pkgs.stdenv.hostPlatform.system}";

  # no window: the machine runs in the terminal that started it, over the serial port. This is
  # why there is a getty on serialDevice below - without one the boot log appears and then
  # nothing does, because the login prompts are all on virtual terminals nobody can see.
  #
  # `mon:stdio` puts the qemu monitor on the same stream, so Ctrl-a c switches to it and
  # Ctrl-a x kills the machine.
  consoleArgs = [
    "-display"
    "none"
    "-serial"
    "mon:stdio"
  ];

  # whatever the selected backend is inspected and driven with, so that logging in gives you
  # something to ask about the running system. The contract deliberately has no opinion here -
  # these are each init's own tooling, and they answer quite different questions.
  inspector = {
    # initctl status, initctl -j status for JSON
    finit = [ ];

    # dinitctl list, dinitctl status <name>
    dinit = [ pkgs.dinit ];

    # sv status /run/service/* - takes the directory, not a bare name, without SVDIR set
    runit = [ pkgs.runit ];

    # s6-rc -l /run/s6-rc -a list, s6-svstat /run/service/<name>
    s6-rc = [
      pkgs.s6
      pkgs.s6-rc
    ];
  };

  common = backend: {
    nixpkgs.pkgs = pkgs;

    # finit's own tooling arrives with finit itself; the others have to be asked for
    environment.systemPackages = inspector.${backend};

    # so `sv status <name>` works without naming /run/service every time
    environment.variables.SVDIR = lib.mkIf (backend == "runit") "/run/service";

    networking.hostName = "finix-${lib.replaceStrings [ "-" ] [ "" ] backend}";

    # the whole of this configuration's opinion about init
    providers.services.backend = backend;
    providers.services.trunk.enable = true;

    # a console to look at and something to log into: root, password "finix".
    #
    # A real hash rather than the empty string, because `login` refuses an empty password and
    # answers "Login incorrect" when it does - indistinguishable from a wrong one. The hash is
    # committed on purpose and the salt is fixed, so every build of this VM has the same
    # throwaway credential. It is a throwaway credential.
    services.getty.enable = true;
    users.users.root.password = "$6$finixvmsalt00$AgxmIXQwMEgYHMrhJ8K61XyTHDXZiYPxAXpcOzLG/Ixz9qPvCISqAmtZHtJrQvUBYop2bM3vEuh53CklTDynI0";

    # the serial port is where the terminal is looking, so that is where the prompt has to be.
    # tty1 is kept for the same machine started with a display.
    services.getty.ttys = [
      "tty1"
      serialDevice
    ];

    # device nodes, so the tty exists to open
    services.mdevd.enable = true;

    # this kernel has no VGA text console, and the DRM drivers which would provide a
    # framebuffer for fbcon to bind to are modules. Without one loaded, tty0 has no device
    # behind it and the qemu window stays black however far the boot gets - which is why the
    # test suite, which only ever uses the serial port, never noticed. `bochs` drives qemu's
    # default `-vga std`; virtio-gpu is there for `-vga virtio`.
    # the serial console last, so it is the one /dev/console resolves to - that is what makes
    # the boot log and any kernel panic land in the terminal rather than on a tty nobody sees
    boot.kernelParams = [
      "console=tty0"
      "console=${serialDevice},115200n8"
    ];

    fileSystems."/" = {
      device = "tmpfs";
      fsType = "tmpfs";
      options = [ "mode=755" ];
    };

    virtualisation = {
      memorySize = 2048;
      cores = 2;

      qemu = {
        # the full qemu rather than qemu_test, which is built without display support
        package = pkgs.qemu;
        mountHostNixStore = true;
        nics.net0.args = [
          "user"
          "model=virtio-net-pci"
        ];

        extraArgs = consoleArgs;
      };
    };
  };

  evaluate =
    backend:
    lib.evalModules {
      class = "nixos";
      specialArgs = {
        modules = finixModules;
      };
      modules = [
        ../modules/virtualisation/qemu.nix
        (common backend)
      ]
      ++ lib.attrValues finixModules;
    };

  mkVm =
    backend:
    let
      name = "finix-${backend}";
      config = (evaluate backend).config;

      script = pkgs.writeShellScript "run-${backend}-vm" ''
        set -e

        # a fresh scratch directory per run, since the VM keeps nothing
        : "''${TMPDIR:=$(${lib.getExe' pkgs.coreutils "mktemp"} -d)}"
        cd "$TMPDIR"

        exec ${lib.escapeShellArgs config.virtualisation.qemu.argv} \
          -name ${lib.escapeShellArg name} \
          "$@"
      '';
    in
    pkgs.runCommand name
      {
        preferLocalBuild = true;

        # the evaluated machine, so the VMs can be compared without booting them - eg.
        #   nix-instantiate --eval --strict -E 'builtins.attrNames
        #     (import ./vms { }).runit.config.providers.services.units'
        passthru = { inherit config; };

        meta = {
          description = "finix VM running ${backend} as PID 1, on the terminal";
          mainProgram = "run-${backend}-vm";
        };
      }
      ''
        mkdir -p $out/bin
        ln -s ${config.system.topLevel} $out/system
        ln -s ${config.boot.init} $out/init
        ln -s ${script} $out/bin/run-${backend}-vm
      '';
in
lib.genAttrs [
  "finit"
  "dinit"
  "runit"
  "s6-rc"
] mkVm
