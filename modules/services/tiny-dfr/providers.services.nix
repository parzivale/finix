{
  config,
  lib,
  ...
}:
let
  cfg = config.services.tiny-dfr;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.tiny-dfr = {
      description = "Apple Touch Bar daemon";

      # multi-user, for the reason the shipped unit orders itself after logind and getty: the
      # daemon takes the Touch Bar's seat, and taking a seat wants the seat manager already
      # there. elogind attaches to `basic`, so `multi-user` is after it.
      #
      # Upstream also binds the unit to three device units, which is how it survives the strip
      # going away on a suspend. There is no device unit here to bind to; a supervised service
      # which exits is restarted, which covers the same ground from the other direction.
      requires = [ "multi-user" ];

      # A daemon which draws until it is stopped, so the default service type is right - and
      # nothing to wait for beyond it being spawned. It opens the DRM device itself and will
      # exit if it cannot, so the restart is the retry.
      type.service.command = lib.getExe cfg.package;

      # The config file is read at startup only, so a changed one means a restart. Named as a
      # reload trigger rather than left implicit: the command does not mention the file, so
      # nothing else would notice it changing.
      reloadTriggers = [ config.environment.etc."tiny-dfr/config.toml".source ];
    };
  };
}
