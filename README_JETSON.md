# ForzaETH Race Stack — NVIDIA Jetson Thor (JetPack 7) Guide

ARM64 / aarch64 deployment guide for the ForzaETH ROS 2 Jazzy race stack on an
NVIDIA Jetson Thor running JetPack 7 (Ubuntu 24.04.3 LTS).

These instructions are **additive** to the existing x86 development setup —
nothing under [.devcontainer/Dockerfile](.devcontainer/Dockerfile),
[docker-compose.yaml](docker-compose.yaml) or [.docker_utils/](.docker_utils/)
is changed. The Jetson-specific assets are:

| File | Purpose |
| --- | --- |
| [.devcontainer/Dockerfile.jetson](.devcontainer/Dockerfile.jetson) | Multi-stage ARM64 image, ROS 2 Jazzy + race stack pre-built |
| [.devcontainer/ros_entrypoint_jetson.sh](.devcontainer/ros_entrypoint_jetson.sh) | Sources `/opt/ros/jazzy/setup.bash` + `ws/install/setup.bash` |
| [docker-compose.jetson.yaml](docker-compose.jetson.yaml) | Compose stack with `runtime: nvidia`, host net, /dev passthrough |

---

## 1 — Prerequisites on the Jetson Thor

### 1.1 JetPack & OS

```bash
# Confirm you're on JetPack 7 / Ubuntu 24.04 / aarch64
lsb_release -a
uname -m            # → aarch64
dpkg-query -W -f='${Version}\n' nvidia-l4t-core 2>/dev/null || cat /etc/nv_tegra_release
```

You should see `Ubuntu 24.04.x LTS` and `aarch64`. If `nvidia-l4t-core` is
missing, you're not on a flashed JetPack image and GPU passthrough won't work.

### 1.2 Docker engine

JetPack 7 ships with Docker pre-installed. Verify and add yourself to the
`docker` group so `sudo` isn't required:

```bash
docker --version
sudo usermod -aG docker "$USER"
newgrp docker   # or log out / back in
docker info | grep -i 'server version'
```

### 1.3 nvidia-container-toolkit (required for GPU / OpenGL)

```bash
# Should already be installed by JetPack; verify:
dpkg -l | grep -E 'nvidia-container-toolkit|nvidia-docker'

# If missing, install from NVIDIA's apt repo:
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

Sanity check the runtime is registered:

```bash
docker info 2>/dev/null | grep -A1 'Runtimes:'
# Should list:  nvidia runc io.containerd.runc.v2
```

### 1.4 X11 access for the host display (only if you want GUIs)

```bash
xhost +local:docker
```

For headless Jetsons skip this; use Foxglove over rosbridge (port 9090)
instead — see §6.

### 1.5 Clone the repo with submodules

The race stack pulls four submodules (f1tenth_system, f1tenth_gym, vesc,
global_racetrajectory_optimization). The image build copies the source tree
as-is and assumes those are checked out.

```bash
git clone -b ros2-jazzy --recurse-submodules \
    https://github.com/ForzaETH/race_stack.git
cd race_stack
git submodule update --init --recursive
```

---

## 2 — Build the image

### Option A — Native build on the Jetson (recommended)

```bash
cd race_stack
docker compose -f docker-compose.jetson.yaml build
```

The image is multi-stage; the first run takes ~25–40 min on a Thor (mostly
ROS 2 desktop apt + matplotlib/quadprog source builds). Subsequent builds
reuse layers and complete in seconds when only the workspace source changes.

### Option B — Cross-build from x86 with `docker buildx`

Useful for CI or for iterating without occupying the Jetson. Requires QEMU
binfmt registration once on the host:

```bash
# One-time on the x86 host:
docker run --privileged --rm tonistiigi/binfmt --install arm64
docker buildx create --use --name racestack-builder
docker buildx inspect --bootstrap

# Build and push to a registry the Jetson can pull from:
cd race_stack
docker buildx build \
    --platform linux/arm64 \
    --file .devcontainer/Dockerfile.jetson \
    --tag <your-registry>/forzaeth_racestack_ros2:jetson \
    --push \
    .

# On the Jetson:
docker pull <your-registry>/forzaeth_racestack_ros2:jetson
docker tag  <your-registry>/forzaeth_racestack_ros2:jetson \
            forzaeth_racestack_ros2:jetson
```

`docker buildx build --load` works too but unpacks the arm64 image into the
x86 daemon, which isn't useful unless you immediately push.

---

## 3 — Run the container with GPU access

### 3.1 With compose (preferred)

```bash
cd race_stack
docker compose -f docker-compose.jetson.yaml up -d
docker compose -f docker-compose.jetson.yaml exec racestack bash
```

The compose file sets `runtime: nvidia`, `network_mode: host`, `privileged:
true`, and mounts `/dev`, `/tmp/.X11-unix`, and `$XAUTHORITY` so LiDAR
(`/dev/ttyACM*`), VESC, the joystick (`/dev/input/js0`) and the host display
are all available without extra flags.

### 3.2 Raw `docker run` (equivalent)

```bash
docker run -it --rm \
    --runtime nvidia \
    --network host \
    --privileged \
    --env DISPLAY="$DISPLAY" \
    --env NVIDIA_DRIVER_CAPABILITIES=all \
    --env ROS_DOMAIN_ID=48 \
    --volume /tmp/.X11-unix:/tmp/.X11-unix:rw \
    --volume "${XAUTHORITY:-$HOME/.Xauthority}:/home/ros/.Xauthority:rw" \
    --volume /dev:/dev \
    --name forzaeth_racestack_jetson \
    forzaeth_racestack_ros2:jetson
```

`--runtime nvidia` is the Jetson-native flag. `--gpus all` is the
discrete-GPU spelling and **does not work on Jetson**; do not substitute it.

### 3.3 Stop / restart

```bash
docker compose -f docker-compose.jetson.yaml down       # stop + remove
docker compose -f docker-compose.jetson.yaml restart    # restart in place
docker logs -f forzaeth_racestack_jetson                # follow stdout
```

---

## 4 — Verify the build

Open a shell in the running container and run the checks below. All commands
are copy-pasteable.

```bash
docker compose -f docker-compose.jetson.yaml exec racestack bash
```

### 4.1 ROS environment is sourced

```bash
echo "$ROS_DISTRO"            # → jazzy
echo "$ROS_DOMAIN_ID"         # → 48
which ros2                     # → /opt/ros/jazzy/bin/ros2
ros2 --help | head -3
```

### 4.2 All race-stack packages are visible to ROS

`ros2 pkg list | wc -l` should be **≥ 320** (≈319 from `ros-jazzy-desktop` +
the race stack overlay). Race-stack-specific packages must all appear:

```bash
ros2 pkg list | grep -E '^(controller|perception|planner|spline_planner|global_planner|stack_master|state_estimation|state_machine|f110_msgs|frenet_conversion|frenet_odom_republisher|lap_analyser|map_editor|opponent_publisher|sector_tuner|slam_tuner|id_controller|steering_lookup|f1tenth_stack|vesc|vesc_driver|vesc_ackermann|vesc_msgs|ackermann_mux|joy_teleop|key_teleop|f1tenth_gym_ros)$' | sort
```

Expected (≈26 lines):

```
ackermann_mux
controller
f110_msgs
f1tenth_gym_ros
f1tenth_stack
frenet_conversion
frenet_odom_republisher
global_planner
id_controller
joy_teleop
key_teleop
lap_analyser
map_editor
opponent_publisher
perception
sector_tuner
slam_tuner
spline_planner
stack_master
state_estimation
state_machine
steering_lookup
vesc
vesc_ackermann
vesc_driver
vesc_msgs
```

### 4.3 Python deps import

```bash
python3 - <<'PY'
import numpy, scipy, casadi, numba, quadprog, cv2, filterpy, skimage, sklearn
import trajectory_planning_helpers as tph
import f110_gym
import global_racetrajectory_optimization as gro
print("numpy", numpy.__version__)
print("scipy", scipy.__version__)
print("casadi", casadi.__version__)
print("numba", numba.__version__)
print("opencv", cv2.__version__)
print("tph", tph.__version__ if hasattr(tph, "__version__") else "ok")
print("f110_gym", f110_gym.__file__)
print("OK")
PY
```

Expected `numpy 1.26.4`, no `ImportError`, final line `OK`.

### 4.4 Bring up a smoke launch & check topics

Start the simulator + state machine in two terminals (or a `tmux` split):

```bash
# Terminal 1
ros2 launch f1tenth_gym_ros gym_bridge_launch.py

# Terminal 2
docker compose -f docker-compose.jetson.yaml exec racestack bash
ros2 topic list
```

Expected topics (subset):

```
/clock
/cmd_vel
/drive
/ego_racecar/odom
/initialpose
/map
/scan
/tf
/tf_static
```

If `/scan`, `/ego_racecar/odom`, and `/map` are present, the workspace
overlay is wired up correctly.

### 4.5 rosbridge_server (port 9090)

```bash
# Inside the container
ros2 launch rosbridge_server rosbridge_websocket_launch.xml &
# On any host on the same network
curl -sI http://<jetson-ip>:9090 ; echo
```

A `Connection: Upgrade` header on the curl response confirms the websocket
endpoint is reachable.

---

## 5 — Known ARM64 / Jetson gotchas for this project

1. **`--gpus all` does not work on Jetson.** Use `--runtime nvidia` (the
   compose file already does). nvidia-container-toolkit on Tegra exposes the
   integrated GPU through the legacy runtime path; the `--gpus` flag is for
   discrete-GPU hosts.

2. **GL acceleration depends on host driver matching.** rviz2 and the
   `f110_gym` viewer (pyglet/OpenGL) render through libraries mounted from
   the host by nvidia-container-toolkit. If you upgrade JetPack on the host,
   rebuild or at least restart the container so the newly-mounted libraries
   are picked up.

3. **`matplotlib~=3.5.1` builds from sdist.** No aarch64 wheel exists for
   matplotlib 3.5.x on Python 3.12, so pip compiles it (~3–5 min on Thor).
   This is intentional — the project pins 3.5.x for compatibility with
   `trajectory_planning_helpers`. The build needs the `build-essential`
   present in the builder stage; do not strip it from
   [.devcontainer/Dockerfile.jetson](.devcontainer/Dockerfile.jetson).

4. **`quadprog` is installed separately from `python_req.txt`** for the same
   reason as on x86: it conflicts with the version `trajectory-planning-helpers`
   would otherwise drag in. The Dockerfile does this in one `RUN` so the layer
   stays cached.

5. **rosdep `python-transforms3d-pip` is skipped.** The key resolves to a pip
   name that `--break-system-packages` would still refuse on Noble; the same
   functionality is provided by apt's `ros-jazzy-tf-transformations`. The
   skip is documented inline in
   [.devcontainer/Dockerfile.jetson](.devcontainer/Dockerfile.jetson).

6. **Legacy ROS 1 imports in `slam_tuner`.**
   [utilities/nodes/slam_tuner/slam_tuner/path_recorder.py](utilities/nodes/slam_tuner/slam_tuner/path_recorder.py)
   and `reconstruction_error.py` still `import rospy` / `from tf.transformations`.
   They are **not** loaded by any ROS 2 entry point, so the colcon build
   succeeds — but invoking those scripts directly will fail. This is a
   pre-existing ROS 1 leftover, not arm64-specific; the constraints
   forbid modifying ROS source so it's left alone.

7. **f1tenth_gym uses `pyglet 1.5.20` + PyOpenGL.** Both are pure Python and
   work on aarch64, but the legacy OpenGL 2.x style they use requires X11
   forwarding or a virtual display. On a headless Jetson, prefer
   `gymnasium`-only headless training (no render call) or attach noVNC; see
   §6.

8. **`--privileged` and `/dev` mount are not optional on the car.** The
   VESC (`/dev/ttyACM*`), Hokuyo LiDAR (`/dev/ttyUSB*`), and joystick
   (`/dev/input/js0`) all need raw device access. If you only run the
   simulator you can drop both, but the compose file keeps them so the
   same image runs unchanged on real hardware.

9. **CycloneDDS over Fast-DDS.** `RMW_IMPLEMENTATION=rmw_cyclonedds_cpp`
   is set in the compose file. Fast-DDS' default shared-memory transport
   has historically misbehaved with `network_mode: host` on aarch64; if
   you specifically need Fast-DDS, unset `RMW_IMPLEMENTATION` in
   [docker-compose.jetson.yaml](docker-compose.jetson.yaml) and add the
   `ros-jazzy-rmw-fastrtps-cpp` apt package (it's already in the desktop
   meta-package).

10. **The image carries `/ws/src` at runtime.** This is required by
    `colcon build --symlink-install` — the overlay setup file references
    files under `src/`. Dropping `src/` to shrink the image will break
    Python entry points. If you want a smaller image, rebuild with a plain
    `colcon build` (no `--symlink-install`) and prune `src/` in a separate
    Dockerfile stage; the task spec asked for symlink-install so the
    shipped Dockerfile keeps it.

---

## 6 — Connecting external tools

### 6.1 Foxglove Studio

`rosbridge_server` is installed (it's a `<depend>` of `f1tenth_stack`) and
port `9090` is exposed by the compose file. From a laptop on the same LAN:

```bash
# Inside the container (start rosbridge once per session)
ros2 launch rosbridge_server rosbridge_websocket_launch.xml
```

In Foxglove Studio:
- *Open connection…* → **Rosbridge (ROS 1 & 2)**
- WebSocket URL: `ws://<jetson-ip>:9090`

### 6.2 foxglove-bridge (lower latency, newer)

Not installed by default; add it without modifying the Dockerfile:

```bash
# Inside the running container
sudo apt-get update && sudo apt-get install -y ros-jazzy-foxglove-bridge
ros2 launch foxglove_bridge foxglove_bridge_launch.xml
# Open ws://<jetson-ip>:8765 in Foxglove Studio
```

To bake it in permanently, append `ros-jazzy-foxglove-bridge` to
[.install_utils/linux_req/linux_req.txt](.install_utils/linux_req/linux_req.txt)
(used by both the x86 and Jetson Dockerfiles) and rebuild. Also add
`- "8765:8765"` to the `ports:` list in
[docker-compose.jetson.yaml](docker-compose.jetson.yaml).

### 6.3 noVNC (headless GUI access)

The `f1tenth_gym_ros` submodule ships its own
[base_system/f110_simulator/f1tenth_gym_ros/docker-compose.yml](base_system/f110_simulator/f1tenth_gym_ros/docker-compose.yml)
with a `theasp/novnc:latest` sidecar on port 8080. To use the same pattern
with the race stack, add to
[docker-compose.jetson.yaml](docker-compose.jetson.yaml):

```yaml
  novnc:
    image: theasp/novnc:latest
    environment:
      - DISPLAY_WIDTH=1728
      - DISPLAY_HEIGHT=972
    ports:
      - "8080:8080"
    network_mode: host
```

Then set `DISPLAY=:0.0` on the `racestack` service environment (override
`${DISPLAY}` in `.env.jetson`) and browse to `http://<jetson-ip>:8080/vnc.html`.
GL-accelerated apps (rviz2, pyglet) work but at reduced frame-rate compared
to native X.

### 6.4 ROS 2 from a remote workstation (no extra ports)

Because the compose file uses `network_mode: host` and sets
`ROS_DOMAIN_ID=48`, any other machine on the same L2 network with the same
`ROS_DOMAIN_ID` and `RMW_IMPLEMENTATION` will discover the Jetson's nodes
automatically:

```bash
# On your workstation (also running ROS 2 Jazzy)
export ROS_DOMAIN_ID=48
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
ros2 topic list
ros2 topic echo /scan
```

---

## 7 — Quick reference

```bash
# Build (native, on the Jetson)
docker compose -f docker-compose.jetson.yaml build

# Up + shell
docker compose -f docker-compose.jetson.yaml up -d
docker compose -f docker-compose.jetson.yaml exec racestack bash

# Inside the container — verify
ros2 pkg list | wc -l        # ≥ 320
ros2 doctor --report          # no critical issues
ros2 topic list

# Down
docker compose -f docker-compose.jetson.yaml down
```

---

[← back to main README](README.md)
