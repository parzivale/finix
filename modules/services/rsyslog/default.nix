{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.rsyslog;

  configFile = pkgs.writeText "rsyslog.conf" ''
    # Load necessary modules
    module(load="imuxsock")    # UNIX socket input (for local logging)
    module(load="imklog")      # Kernel log messages

    # Global settings
    $MaxMessageSize 64k
    $ModLoad immark
    $ActionFileDefaultTemplate RSYSLOG_TraditionalFileFormat
    $RepeatedMsgReduction on

    # Rate limiting
    $SystemLogRateLimitInterval 5
    $SystemLogRateLimitBurst 1000

    # Logging rules
    *.*;auth,authpriv.none      -/var/log/syslog
    auth,authpriv.*             -/var/log/auth.log
    kern.*                      -/var/log/kern.log
    mail.*                      -/var/log/mail.log
    cron.*                      -/var/log/cron.log
    daemon.*                    -/var/log/daemon.log
    user.*                      -/var/log/user.log
    *.emerg                     :omusrmsg:*
    *.alert                     -/var/log/alert.log

    $IncludeConfig /etc/rsyslog.d/*.conf
  '';
in
{
  options.services.rsyslog = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [rsyslog](${pkgs.rsyslog.meta.homepage}) as a system service.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # the two are alternatives under one name, so this one being on means the other is off.
    # Plain `false` rather than `mkForce`: it overrides a default, and a machine which asks
    # for sysklogd outright as well gets a conflict, which is what enabling two syslog daemons
    # deserves.
    services.sysklogd.enable = false;

    providers.services.units.syslogd = {
      description = "system logging daemon";

      type.service = {
        command = "${pkgs.rsyslog-light}/bin/rsyslogd -n -d -f ${configFile}";

        # `-n` is foreground, so ready-on-fork is the only honest answer here - the same
        # bargain sysklogd makes, and for the same reason
        readiness = "fork";
      };

      # the head of the trunk, so logging is up before `sysinit` and everything in a later
      # tier can log without naming it. The device manager comes first where there is one:
      # /dev/log has to exist before anything can log to it. This is the same shape as
      # sysklogd's unit, deliberately - the two are alternatives under one name, and a
      # machine enabling both is one definition of `syslogd` colliding with another, which
      # is exactly the error it should be.
      requires = [
        (lib.head config.providers.services.trunk.levels)
      ]
      ++ lib.optional config.services.udev.enable "udev-settle"
      ++ lib.optional config.services.mdevd.enable "coldplug";
    };

    system.switch.inhibitors.syslogd = config.providers.services.units.syslogd.type.service.command;

    services.logrotate.rules.rsyslog = {
      text = ''
        /var/log/syslog
        /var/log/auth.log
        /var/log/kern.log
        /var/log/mail.log
        /var/log/cron.log
        /var/log/daemon.log
        /var/log/user.log
        /var/log/alert.log
        {
          rotate 7
          daily
          missingok
          notifempty
          compress
          delaycompress
          sharedscripts

          postrotate
            ${lib.getExe' config.programs.coreutils.package "kill"} -s HUP $(cat /run/rsyslog.pid)
          endscript
        }
      '';
    };
  };
}
