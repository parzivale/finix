#!@bash@/bin/bash
set -euo pipefail

out="@out@"
localeArchive="@localeArchive@"
distroId="@distroId@"
installHook="@installHook@"
inhibitCheck="@inhibitCheck@"
finit="@finit@"
logger="@logger@"
coreutils="@coreutils@"
servicesSwitch="@servicesSwitch@"

action="${1-}"

# if [[ -n "$localeArchive" ]]; then
#   export LOCALE_ARCHIVE="$localeArchive"
# fi

case "$action" in
  switch|boot|test)
    ;;
  *)
    cat >&2 <<EOF
Usage: $0 [switch|boot|test]

switch:       make the configuration the boot default and activate now
boot:         make the configuration the boot default
test:         activate the configuration, but don't make it the boot default
EOF
    exit 1
    ;;
esac

# Verify this is a NixOS system
if [[ ! -f /etc/NIXOS && ! "$(grep -E "^ID=\"?$distroId\"?" /etc/os-release 2>/dev/null || true)" ]]; then
  echo "This is not a NixOS installation!" >&2
  exit 1
fi

# mkdir -p -m 755 /run/finix
# 
# # Acquire lock
# exec {lockfd}>/run/finix/switch-to-configuration.lock
# if ! flock -n "$lockfd"; then
#   echo "Could not acquire lock" >&2
#   exit 1
# fi

"$logger/bin/logger" -t finix "starting switch-to-configuration ($action)"

if [[ "$action" != boot && "${NIXOS_NO_CHECK-}" != 1 ]]; then
  if ! "$inhibitCheck" "$out"; then
    exit 1
  fi
fi

# install bootloader
if [[ "$action" == switch || "$action" == boot ]]; then
  if ! "$installHook" "$out"; then
    exit 1
  fi
fi

# sync filesystem
if [[ "${NIXOS_NO_SYNC-}" != 1 ]]; then
  "$coreutils/bin/sync" -f /nix/store || true
fi

if [[ "$action" == boot ]]; then
  exit 0
fi

"$logger/bin/logger" -t finix "switching to system configuration $out"
echo "activating the configuration..." >&2

res=0
if ! "$out/activate"; then
  res=2
fi

# Reconcile the running services against the incoming ones. Everything init-specific lives
# behind this: the engine is the same whatever init is underneath, and the selected
# providers.services implementation supplies the three operations it drives.
#
# A system defining no providers.services units has no such implementation to call, so it
# falls back to asking finit to reload directly, as it always did.
if [[ -n "$servicesSwitch" ]]; then
  if ! "$servicesSwitch"; then
    (( res == 0 )) && res=3
  fi
elif ! "$finit/bin/initctl" reload; then
  (( res == 0 )) && res=3
fi

if (( res == 0 )); then
  "$logger/bin/logger" -t finix "finished switching to system configuration $out"
else
  "$logger/bin/logger" -t finix -p user.err "switching to system configuration $out failed (status $res)"
fi

exit "$res"
