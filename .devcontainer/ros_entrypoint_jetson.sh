#!/usr/bin/env bash
# Entrypoint for the Jetson image. Sources ROS 2 Jazzy and the overlay
# workspace, then execs whatever command was passed in (default: bash).
set -e
source "/opt/ros/${ROS_DISTRO}/setup.bash"
if [ -f "/home/${USERNAME}/ws/install/setup.bash" ]; then
    # shellcheck disable=SC1091
    source "/home/${USERNAME}/ws/install/setup.bash"
fi
exec "$@"
