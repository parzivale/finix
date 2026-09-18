{
  lib,
  stdenv,
  fetchFromGitHub,

  meson,
  ninja,
  pkg-config,

  libcap,
  pam,
  audit,
  libselinux,

  # not build inputs: openrc's own shell helpers call these by name, and the path they are
  # found on is one openrc itself decides (see RC_PATH_PREFIX below), so they have to be named
  # here to be named there. `_setup_cgroup` in openrc-run.sh greps /proc/1/mountinfo on every
  # single service start, and rc-cgroup.sh mkdirs beside it.
  coreutils,
  gnugrep,

  # SELinux off by default. It is `auto` in meson, which means "on if libselinux happens to be
  # around" - a dependency decided by what else is in scope rather than by anyone asking for
  # it. Said `disabled` outright, so the answer does not change because something unrelated
  # pulled libselinux into the build.
  #
  # It is not free when on: openrc then also wants pam_misc, or libcrypt where pam is off.
  withSelinux ? false,

  # the same shape of option, and the same reason for naming it. openrc uses it to log service
  # starts and stops to the audit subsystem, which is worth having on a machine that runs one
  # and is a dependency on a machine that does not.
  withAudit ? false,

  # openrc's own `start-stop-daemon` and `supervise-daemon` authenticate with it when asked to
  # run something as another user
  withPam ? true,

  # what `rc` runs a service's shell script with. /bin/sh on a finix machine is dash, put there
  # by activation, which is the whole reason it can be named here at all.
  shell ? "/bin/sh",

  # the group openrc gives /run/lock to. Upstream says `uucp`, which is a serial-line
  # convention from long before this, and a machine without that group gets `checkpath: owner
  # 'root:uucp' not found` on every boot - an error, about a directory finix has already
  # mounted itself, which trains a reader to skim past the ones that matter.
  lockGroup ? "root",

  # printed by `openrc --version` and by the boot banner
  branding ? null,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "openrc";
  version = "0.64";

  __structuredAttrs = true;
  strictDeps = true;

  src = fetchFromGitHub {
    owner = "OpenRC";
    repo = "openrc";
    tag = finalAttrs.version;
    hash = "sha256-qy/ldqLO9sXuPmUAiFW2QWdqPdnHY03OxFVkzkvn6/Q=";
  };

  nativeBuildInputs = [
    meson
    ninja
    pkg-config
  ];

  buildInputs = [
    # not optional on Linux: meson asks for it with no `required:` at all, so a build without
    # it fails rather than doing without
    libcap
  ]
  ++ lib.optional withPam pam
  ++ lib.optional withAudit audit
  ++ lib.optional withSelinux libselinux;

  mesonFlags = [
    (lib.mesonEnable "selinux" withSelinux)
    (lib.mesonEnable "audit" withAudit)
    (lib.mesonBool "pam" withPam)

    # openrc's own init, which is not what runs here: the whole point of the providers.services
    # contract is that something else is PID 1 and openrc supervises under it. Building the
    # sysvinit compatibility on top would install an /sbin/init nothing asked for.
    (lib.mesonBool "sysvinit" false)

    # network configuration of its own, superseded by the ifupdown-ng and networkmanager
    # modules here. Left on it installs a second answer to the same question.
    (lib.mesonBool "newnet" false)

    (lib.mesonBool "bash-completions" false)
    (lib.mesonBool "zsh-completions" false)

    (lib.mesonOption "shell" shell)
    (lib.mesonOption "uucp_group" lockGroup)
    # openrc bakes its configuration directory in at compile time, and everything it looks for
    # at runtime hangs off it: RC_INITDIR, RC_RUNLEVELDIR, RC_CONF, the compiled-in search path
    # librc hands to the shell helpers as $RC_SCRIPTDIRS. meson's default for this is the
    # relative `etc`, meant to be joined onto a prefix, and openrc joins it onto nothing - so
    # every one of those paths comes out relative and resolves against whatever the current
    # directory happens to be.
    #
    # For PID 1 that directory is `/`, so a machine boots and the breakage stays hidden until
    # something runs from elsewhere: gendepends.sh, which `rc` runs to build the dependency
    # tree, reported `cannot open etc/init.d/<service>` for every service on the machine while
    # the runlevels themselves appeared to start fine.
    "--sysconfdir=/etc"
  ]
  ++ lib.optional (branding != null) (lib.mesonOption "branding" branding);

  # meson installs the runlevel symlinks by absolute path, which lands them outside $out. The
  # relative form is the same link, made somewhere the build is allowed to write.
  postPatch = ''
    substituteInPlace runlevels/meson.build \
      --replace-fail \
        "pointing_to: init_d_dir / service)" \
        "pointing_to: '../../init.d/' + service)" \
      --replace-fail \
        "pointing_to: init_d_dir / 'agetty.' + tty)" \
        "pointing_to: '../../init.d/agetty.' + tty)"

    # openrc-init is PID 1, and the first thing it does is overwrite PATH with a compiled-in
    # default and exec `openrc` by name. On a machine with no /sbin - which is every machine
    # here - that exec fails, PID 1 exits, and the kernel panics with "Attempted to kill init"
    # before anything has run. Its own bin is prepended, which is all this one needs: the only
    # thing openrc-init looks up by name is openrc itself.
    substituteInPlace src/openrc-init/openrc-init.c \
      --replace-fail \
        '"/sbin:/usr/sbin:/bin:/usr/bin"' \
        '"${placeholder "out"}/bin:/sbin:/usr/sbin:/bin:/usr/bin"'

    # and the same thing again for everything openrc starts, by a different route. PATH is not
    # on openrc's environment allowlist, so env_filter() unsets it outright and env_config()
    # puts RC_PATH_PREFIX there instead - which means the PATH above reaches `openrc` and no
    # further, and every service on the machine runs with whatever this says and nothing else.
    #
    # What it said was openrc's helper directory and four paths which do not exist here. So a
    # service could not find `supervise-daemon`, which is how it is supervised, nor `grep`,
    # which openrc's own shell helpers call on every start. Its bin goes on, and the two tools
    # those helpers need, which openrc has always depended on without declaring.
    substituteInPlace src/librc/rc.h.in \
      --replace-fail \
        'RC_LIBEXECDIR "/bin:/bin:/sbin:/usr/bin:/usr/sbin"' \
        'RC_LIBEXECDIR "/bin:${placeholder "out"}/bin:${coreutils}/bin:${gnugrep}/bin:/bin:/sbin:/usr/bin:/usr/sbin"'

    # and openrc's shell helpers call openrc's own binaries by bare name, which is a lookup
    # through whatever PATH happens to be rather than a reference to the package they were
    # installed beside. Not a thing a store path may rely on - and not a thing worth debugging
    # twice, which is what the last round was: every service failed with `supervise-daemon: not
    # found` while the binary sat in $out/bin and $out/bin was demonstrably on the prefix.
    #
    # Said absolutely, the question does not arise, and nix sees the dependency it already had.
    substituteInPlace sh/supervise-daemon.sh \
      --replace-fail 'eval supervise-daemon "' 'eval ${placeholder "out"}/bin/supervise-daemon "' \
      --replace-fail '	supervise-daemon "' '	${placeholder "out"}/bin/supervise-daemon "'

    substituteInPlace sh/start-stop-daemon.sh \
      --replace-fail 'eval start-stop-daemon --start' 'eval ${placeholder "out"}/bin/start-stop-daemon --start' \
      --replace-fail '	start-stop-daemon --stop' '	${placeholder "out"}/bin/start-stop-daemon --stop'

    substituteInPlace sh/rc-functions.sh \
      --replace-fail 'rc-service --exists' '${placeholder "out"}/bin/rc-service --exists'

    substituteInPlace sh/functions.sh.in \
      --replace-fail 'rc-status --runlevel' '${placeholder "out"}/bin/rc-status --runlevel'

    substituteInPlace sh/init.sh.Linux.in \
      --replace-fail 'sys="$(openrc --sys)"' 'sys="$(${placeholder "out"}/bin/openrc --sys)"'

    substituteInPlace sh/openrc-user.sh.in \
      --replace-fail 'openrc --user boot' '${placeholder "out"}/bin/openrc --user boot' \
      --replace-fail 'exec openrc --user "' 'exec ${placeholder "out"}/bin/openrc --user "' \
      --replace-fail 'exec openrc --user shutdown' 'exec ${placeholder "out"}/bin/openrc --user shutdown'
  '';

  # ...and an absolute sysconfdir is one meson installs to literally, which is not a place this
  # build may write. Staged instead: the install runs against a directory of its own, and the
  # two trees it produces - the prefix, and /etc - are put where they belong afterwards. What
  # lands in $out/etc is openrc's stock service scripts and rc.conf, which a machine here does
  # not use (the module generates its own /etc/init.d) but which belong in the package all the
  # same, as the reference for what a runscript is allowed to say.
  preInstall = ''
    export DESTDIR="$NIX_BUILD_TOP/stage"
  '';

  postInstall = ''
    stage="$NIX_BUILD_TOP/stage"
    mkdir -p "$out"
    cp -a "$stage$out"/. "$out"/
    cp -a "$stage/etc" "$out/etc"
    rm -rf "$stage"
  '';

  meta = {
    description = "The OpenRC init system";
    homepage = "https://github.com/OpenRC/openrc";
    license = lib.licenses.bsd2;
    mainProgram = "openrc";
    platforms = lib.platforms.unix;
  };
})
