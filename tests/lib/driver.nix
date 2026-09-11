# finix test driver - extends nixos test driver with FinitMachine support
{ pkgs }:

let
  nixosTestDriver = pkgs.python3Packages.callPackage (pkgs.path + "/nixos/lib/test-driver") {
    nixosTests = { }; # stub, only used for passthru.tests
  };
in
nixosTestDriver.overrideAttrs (old: {
  pname = "finix-test-driver";

  postPatch = (old.postPatch or "") + ''
    cp ${./finit_machine.py} test_driver/finit_machine.py

    # The serial reader is the only thread the driver creates without `daemon`, and the only
    # place it is joined is `Machine.release()` - which returns early when `self.pid is None`.
    # A test which powers its machine off clears `pid` in `wait_for_shutdown`, so cleanup skips
    # the join and the non-daemon thread then keeps the interpreter alive after a passing test,
    # until the global timeout fires and terminates it.
    #
    # Whether it hangs or merely warns is a race with the driver noticing the shutdown, which
    # is why it shows up when several VM tests run at once and not when one runs alone.
    substituteInPlace test_driver/machine/__init__.py \
      --replace-fail \
        'self.serial_thread = threading.Thread(target=process_serial_output)' \
        'self.serial_thread = threading.Thread(target=process_serial_output, daemon=True)'
  '';
})
