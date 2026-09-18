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
  '';

  # openrc's install wants to write to the real filesystem root. DESTDIR=/ keeps meson from
  # prefixing it a second time, since the prefix already points into $out.
  preInstall = ''
    export DESTDIR=/
  '';

  meta = {
    description = "The OpenRC init system";
    homepage = "https://github.com/OpenRC/openrc";
    license = lib.licenses.bsd2;
    mainProgram = "openrc";
    platforms = lib.platforms.unix;
  };
})
