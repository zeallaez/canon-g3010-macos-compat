#!/bin/sh
set -eu

# AirSane 0.4.x adds a SANE device to its HTTP server after its internal
# Bonjour registration succeeds. Docker Desktop does not forward that mDNS
# packet to macOS, so a private Avahi daemon satisfies AirSane here while the
# host-side launch agent publishes the actual _uscan service.
mkdir -p /run/dbus
rm -f /run/dbus/pid /run/avahi-daemon/pid
dbus-daemon --system --fork
avahi-daemon --daemonize --no-drop-root

exec airsaned "$@"
