# a realistic userspace stack expressed entirely through providers.services
#
# where tests/providers/services.nix uses synthetic `sleep infinity` units to isolate the
# contract's mechanics, this one runs real daemons with real startup work - a database which
# takes measurable time to accept connections, and a web server which must not start until it
# does - to find out whether the contract's vocabulary is enough to describe an actual system.
{
  name = "providers.services-realistic";

  nodes.machine =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    let
      pg = pkgs.postgresql;
      dataDir = "/var/lib/postgresql/${pg.psqlSchema}";
      sock = "/run/postgresql";

      # units get whatever PATH finit hands them, which is deliberately minimal. these are
      # real programs from real packages, so say where they are.
      script =
        name: body:
        pkgs.writeShellScript name ''
          export PATH=${
            lib.makeBinPath [
              pkgs.coreutils
              pg
            ]
          }:$PATH
          ${body}
        '';
    in
    {
      services.mdevd.enable = true;
      services.getty.enable = true;

      environment.systemPackages = [
        pg
        pkgs.curl
      ];

      users.users.postgres = {
        name = "postgres";
        group = "postgres";
        home = dataDir;
        uid = config.ids.uids.postgres;
      };
      users.groups.postgres.gid = config.ids.gids.postgres;

      providers.services.backend = "finit";
      providers.services.trunk.enable = true;

      providers.services.units = {
        # ---- sysinit: state that everything later assumes exists ----
        state-dirs = {
          type = "oneshot";
          description = "create service state directories";
          requires = [ "start" ];
          command = script "state-dirs" ''
            mkdir -p /var/lib/postgresql ${dataDir} ${sock} /var/www /run/svc-test
            chmod 1777 /run/svc-test
            chown -R postgres:postgres /var/lib/postgresql ${sock}
            chmod 0750 /var/lib/postgresql ${dataDir}
            echo "finix" > /var/www/index.html
          '';
        };

        # ---- basic: database bring-up, as a real multi-step chain ----
        pg-init = {
          type = "oneshot";
          description = "initialise the postgres cluster";
          requires = [ "sysinit" ];
          user = "postgres";
          environment.HOME = dataDir;
          command = script "pg-init" ''
            if [ ! -f "${dataDir}/PG_VERSION" ]; then
              ${lib.getExe' pg "initdb"} --allow-group-access -D ${dataDir}
            fi
          '';
        };

        postgres = {
          description = "postgres database server";
          requires = [ "pg-init" ];
          user = "postgres";
          group = "postgres";
          environment.HOME = dataDir;
          # postgres forks nothing and reports nothing, so `fork` readiness is a lie here -
          # finit calls it ready the moment it execs, long before it accepts connections.
          # that lie is what `pg-ready` below exists to correct.
          readiness = "fork";
          stopTimeout = 120;
          command = "${lib.getExe' pg "postgres"} -D ${dataDir} -k ${sock}";
        };

        # the honest readiness gate: a oneshot which does not succeed until the database
        # actually answers. anything needing a working database depends on this, not on
        # `postgres` itself.
        pg-ready = {
          type = "oneshot";
          description = "wait for postgres to accept connections";
          requires = [ "postgres" ];
          user = "postgres";
          command = script "pg-ready" ''
            for _ in $(seq 1 100); do
              if ${lib.getExe' pg "pg_isready"} -q -h ${sock}; then
                touch /run/svc-test/pg-ready
                exit 0
              fi
              sleep 0.2
            done
            touch /run/svc-test/pg-timeout
            exit 1
          '';
        };

        db-setup = {
          type = "oneshot";
          description = "create the application schema";
          requires = [ "pg-ready" ];
          user = "postgres";
          command = script "db-setup" ''
            ${lib.getExe' pg "psql"} -h ${sock} -U postgres -d postgres \
              -c "create table if not exists finix (id int)" \
              -c "insert into finix values (1)"
            touch /run/svc-test/db-setup
          '';
        };

        # ---- multi-user: userspace which depends on things brought up before it ----
        web = {
          description = "web server";
          # one trunk level, plus a direct edge to work which is not attached to any level
          requires = [
            "multi-user"
            "db-setup"
          ];
          command = script "web" ''
            touch /run/svc-test/web.started
            exec ${pkgs.busybox}/bin/busybox httpd -f -p 8080 -h /var/www
          '';
        };

        # records whether the database happened to be up when `multi-user` was reached. it
        # generally will not be: a level waits for the units attached to the previous level,
        # not for what chains off them, so the database subsystem runs past it. that is the
        # intended behaviour rather than a gap - a level is somewhere to attach, and anything
        # which actually needs the database says so directly, as `web` does below.
        mu-probe = {
          type = "oneshot";
          description = "probe database state at multi-user";
          requires = [ "multi-user" ];
          user = "postgres";
          command = script "mu-probe" ''
            if ${lib.getExe' pg "pg_isready"} -q -h ${sock}; then
              touch /run/svc-test/mu-db-ready
            else
              touch /run/svc-test/mu-db-not-ready
            fi
          '';
        };
      };
    };

  testScript = ''
    import json

    def status(name):
        return json.loads(machine.succeed(f"initctl -j status {name}"))["status"]

    machine.start()

    machine.wait_for_console_text("finix - stage 1")
    machine.wait_for_console_text("entering runlevel 2")

    with subtest("the database chain completed"):
        # marker files rather than console writes: these units run as `postgres`, and a
        # non-root write to /dev/console fails silently in a script without `set -e`
        machine.wait_until_succeeds("test -f /run/svc-test/pg-ready", timeout=120)
        machine.fail("test -f /run/svc-test/pg-timeout")
        machine.wait_until_succeeds("test -f /run/svc-test/db-setup", timeout=120)

    with subtest("postgres is genuinely serving"):
        machine.succeed(
            "su postgres -s /bin/sh -c "
            "'psql -h /run/postgresql -U postgres -d postgres -tAc \"select count(*) from finix\"'"
            " | grep -q 1"
        )

    with subtest("the web server started, behind its database dependency"):
        # it must not have started before the schema existed
        machine.succeed("test -f /run/svc-test/web.started")
        machine.succeed("test -f /run/svc-test/db-setup")
        machine.wait_until_succeeds(
            "curl -sf http://localhost:8080/ | grep -q finix", timeout=60
        )

    with subtest("every unit reached a terminal good state"):
        for svc in ["postgres", "web"]:
            assert status(svc) == "running", f"{svc} is {status(svc)}"
        for task in ["state-dirs", "pg-init", "pg-ready", "db-setup", "mu-probe"]:
            assert status(task) == "done", f"{task} is {status(task)}"

    with subtest("a level is an attachment point, not a barrier"):
        machine.succeed("test -f /run/finit/cond/task/multi-user/success")

        # informational: `multi-user` is reached without waiting for the database subsystem,
        # because only `pg-init` is attached to a level. units needing the database say so
        # directly instead - which is what `web` does, and why it started correctly anyway.
        ready = machine.succeed(
            "test -f /run/svc-test/mu-db-ready && echo ready || echo not-ready"
        ).strip()
        print(f"database state when multi-user was reached: {ready}")

    machine.shutdown()
  '';
}
