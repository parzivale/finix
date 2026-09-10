- `providers.` namespace is a mechanism to abstract software implementations from high level concepts
- `providers.scheduler` - a high level abstraction over `cron` (`fcron`, `mcron`, `jobber`, `systemd.timers`, etc...), for example:

```
  providers.scheduler.tasks = {
    logrotate = {
      interval = "hourly";
      command = "${cfg.package}/bin/logrotate ${configFile}";
    };
  };
```

- `providers.services` - a high level abstraction over the init system (`finit`, `dinit`, `systemd`, etc...). Units
  are a dependency graph and nothing else: a unit starts once every unit it requires is ready, and there is no other
  mechanism for starting one - no runlevels, no enablement, no activation events. Dependencies gate starting only, so
  a unit is unaffected by what later happens to what it required. For example:

```
  providers.services.units = {
    pg-init = {
      type = "oneshot";
      command = "${cfg.package}/bin/initdb -D ${cfg.dataDir}";
      requires = [ "sysinit" ];
    };

    postgres = {
      command = "${cfg.package}/bin/postgres -D ${cfg.dataDir}";
      requires = [ "pg-init" ];
      stopTimeout = 120;
    };
  };
```

  Interchangeable implementations are selected by their own `providers.` contract and define the same unit name, so
  dependants name the concept rather than the implementation - `requires = [ "syslogd" ]`, whichever logger is in use.

  `providers.services.trunk` optionally defines a chain of process-less units standing in for runlevels. A level is
  somewhere to attach, not a barrier: it orders the tiers coarsely, but only waits for the units which named it, so
  anything that genuinely needs a subsystem must require that subsystem's unit directly.

- `providers.privileges` - a high level abstraction over `sudo` (`sudo-rs`, `doas`, `please`, etc...), for example:

```
  providers.privileges.rules = [
    { command = "/run/current-system/sw/bin/reboot";
      groups = [ "automation" ];
    }
  ];
```
