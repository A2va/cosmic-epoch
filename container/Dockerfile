FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# trusted=yes skips Pop archive key verification; fine for a disposable dev image
RUN echo "deb [trusted=yes] https://apt.pop-os.org/release noble main" \
      > /etc/apt/sources.list.d/pop-os.list \
 && apt-get update

# --- Build dependencies: compile COSMIC and its submodules ------------------
RUN apt-get install -y --no-install-recommends \
      bash ca-certificates curl git sudo xz-utils \
      build-essential clang cmake libclang-dev make meson ninja-build pkg-config scdoc \
      libdbus-1-dev libexpat1-dev libpam0g-dev libssl-dev \
      libdrm-dev libegl-dev libgbm-dev libgl-dev libpixman-1-dev \
      libwayland-dev libx11-xcb-dev libxkbcommon-dev wayland-protocols \
      libdisplay-info-dev libinput-dev libseat-dev libudev-dev \
      libasound2-dev libdav1d-dev libgstreamer-plugins-base1.0-dev \
      libgstreamer1.0-dev libpulse-dev libpipewire-0.3-dev \
      libfontconfig-dev libfreetype-dev \
      libflatpak-dev

# --- Runtime / script dependencies: boot & drive COSMIC inside the image ---
# systemd (already in the ubuntu base fs) runs as PID 1 for `dev.sh dm` —
# real dbus.service, journald and systemd-logind instead of hand-rolled stubs.
RUN apt-get install -y --no-install-recommends \
      dbus dbus-user-session \
      greetd \
      gtk-update-icon-cache hicolor-icon-theme \
      pipewire pipewire-bin \
      fonts-dejavu-core wl-clipboard \
 && rm -rf /var/lib/apt/lists/*

# noble ships an 'ubuntu' user with uid 1000; rename it instead of adding another
RUN usermod -l dev -d /home/dev -m ubuntu \
 && groupmod -n dev ubuntu \
 && echo 'dev ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/dev

# greetd's deb enables itself as display-manager.service; it would crash-loop
# at boot (no kernel VTs in a container). scripts/inside-dm.sh points
# the display-manager alias at cosmic-greeter.service instead.
RUN rm -f /etc/systemd/system/display-manager.service

# Normally created at boot by systemd-sysusers from cosmic-greeter.sysusers;
# /etc is not image-writable in a running container, so create the user here
# instead (same fields as the sysusers file).
RUN useradd \
    --system \
    --user-group \
    --home-dir /var/lib/cosmic-greeter \
    --create-home \
    --shell /usr/sbin/nologin \
    cosmic-greeter

# Rust & just via mise, installed into the system-wide shared directory so
# every user (dev and root under sudo) resolves them without env tricks.
# rustup must be told to live outside /root, else 'stable' symlinks there;
# we link the real toolchain binaries since the proxies require RUSTUP_HOME in env.
RUN curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh \
 && export RUSTUP_HOME=/usr/local/share/rustup CARGO_HOME=/usr/local/share/cargo \
 && mise install --system rust@stable just@latest \
 && ln -sf /usr/local/share/mise/installs/just/latest/just /usr/local/bin/just \
 && ln -sf "$RUSTUP_HOME"/toolchains/*/bin/cargo /usr/local/bin/cargo \
 && ln -sf "$RUSTUP_HOME"/toolchains/*/bin/rustc /usr/local/bin/rustc \
 && chmod -R a+rX /usr/local/share/mise /usr/local/share/rustup /usr/local/share/cargo

WORKDIR /cosmic-epoch
# systemd as PID 1 by default: the devcontainer (overrideCommand: false) and
# scripts/dev.sh boot a real init; a shell is one exec away.
CMD ["/sbin/init"]
