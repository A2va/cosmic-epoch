FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive
# 'mise run install' puts pop-launcher in dev's ~/.local/bin (its justfile
# ignores prefix), and cosmic-launcher spawns it as a bare `pop-launcher`
# via PATH. Without this, a launcher started from a plain `enter` shell
# finds no pop-launcher, gets no search responses, and never shows its
# window — silently. inside-de.sh sets the same PATH for the DE session.
ENV PATH="/home/dev/.local/bin:${PATH}"

# trusted=yes skips Pop archive key verification; fine for a disposable dev image
RUN echo "deb [trusted=yes] https://apt.pop-os.org/release noble main" \
    > /etc/apt/sources.list.d/pop-os.list \
    && apt-get update

# Build deps: compile COSMIC and its submodules.
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

# Runtime deps; systemd runs as PID 1 for `scripts/enter.sh dm`.
RUN apt-get install -y --no-install-recommends \
    dbus dbus-user-session \
    greetd \
    seatd \
    bsdextrautils \
    gtk-update-icon-cache hicolor-icon-theme \
    pipewire pipewire-bin \
    fonts-dejavu-core wl-clipboard \
    && rm -rf /var/lib/apt/lists/*

# Rename ubuntu (uid 1000) to dev; password 'cosmic' for the greeter login.
# -c SHA512: yescrypt's (chpasswd default) ~16MB buffer can't mmap inside greetd's mlockall()ed
# worker (8MB RLIMIT_MEMLOCK), so pam_unix would reject EVERY password.
# env_keep: sudo's env_reset drops DEBUG, so 'DEBUG=0 sudo ./scripts/install.sh X' silently
# installs debug artifacts (the justfile defaults to DEBUG=1).
RUN usermod -l dev -d /home/dev -m ubuntu \
    && groupmod -n dev ubuntu \
    && echo 'dev ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/dev \
    && echo 'Defaults env_keep += "DEBUG COSMIC_ROOTDIR COSMIC_PREFIX"' > /etc/sudoers.d/dev-env \
    && echo 'dev:cosmic' | chpasswd -c SHA512

# greetd's deb enables itself as display-manager; it crash-loops with no
# kernel VTs in a container. Alias points at cosmic-greeter.service instead.
RUN rm -f /etc/systemd/system/display-manager.service

# sysusers can't run at boot (/etc not writable in a running container),
# so create the greeter user here with the same fields.
RUN useradd \
    --system \
    --user-group \
    --home-dir /var/lib/cosmic-greeter \
    --create-home \
    --shell /usr/sbin/nologin \
    cosmic-greeter

# Static session config (repo/host-display independent). Task caps: a session
# bursts past stock TasksMax and dies with EAGAIN spawning applet threads —
# raise it on the system manager, the user-.slice template, and the user
# manager (inherited by every cosmic-*.scope). Linger dev at build time so
# the user manager is up before any session.
RUN install -d /etc/systemd/system/user-.slice.d /etc/systemd/user.conf.d /etc/systemd/system.conf.d \
    && printf '[Slice]\nTasksMax=4096\n' > /etc/systemd/system/user-.slice.d/10-tasks.conf \
    && printf '[Manager]\nDefaultTasksMax=4096\n' > /etc/systemd/user.conf.d/10-tasks.conf \
    && printf '[Manager]\nDefaultTasksMax=4096\n' > /etc/systemd/system.conf.d/10-tasks.conf \
    && mkdir -p /var/lib/systemd/linger && touch /var/lib/systemd/linger/dev

# Greeter session, static parts (per-run host display comes via pam_env from
# /etc/environment). vt="none": containers have no kernel VTs.
# greetd's worker mlockall()s under 8MB RLIMIT_MEMLOCK, so the stock `@include
# login` stack doesn't fit — minimum greeter set below. The user-session stack
# drops pam_limits (2MB memlock for nothing), pam_selinux (no-op), and
# pam_gnome_keyring (not installed; its faulty auth line fails every login).
# tmpfiles creates /run/cosmic-greeter (a11y state shared with settings-daemon).
RUN install -d /etc/greetd \
    && printf '%s\n' \
    '# container variant of cosmic-greeter.toml — no kernel VTs' \
    '[terminal]' \
    'vt = "none"' \
    '' \
    '[general]' \
    'service = "cosmic-greeter"' \
    '' \
    '[default_session]' \
    'command = "/usr/local/bin/cosmic-greeter-start"' \
    'user = "cosmic-greeter"' \
    > /etc/greetd/cosmic-greeter.toml \
    && printf '#!/bin/bash\nexec >>/tmp/cosmic-greeter.log 2>&1\nset -x\nexec cosmic-comp cosmic-greeter\n' \
    > /usr/local/bin/cosmic-greeter-start \
    && chmod 0755 /usr/local/bin/cosmic-greeter-start \
    && printf '%s\n' \
    '#%PAM-1.0' \
    'auth     requisite pam_nologin.so' \
    'auth     required  pam_permit.so' \
    'account  required  pam_permit.so' \
    'session  required  pam_unix.so' \
    'session  optional  pam_env.so' \
    'session  optional  pam_systemd.so' \
    > /etc/pam.d/greetd-greeter \
    && printf 'd\t/var/lib/cosmic-greeter\t0750\tcosmic-greeter\tcosmic-greeter\nd\t/run/cosmic-greeter\t0755\tcosmic-greeter\tcosmic-greeter\t-\n' \
    > /usr/lib/tmpfiles.d/cosmic-greeter.conf

# Rust & just via mise, system-wide so dev and root share them. The tool
# set (rust incl. clippy/rustfmt, just) comes from the repo's mise.toml —
# single source of truth; the build context is the repo root (.dockerignore
# allows only this file + .devcontainer). RUSTUP_HOME must live outside
# /root, else 'stable' symlinks there; link the real binaries since the
# rustup proxies require RUSTUP_HOME in env.
COPY mise.toml /tmp/mise.toml
RUN curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh \
    && export RUSTUP_HOME=/usr/local/share/rustup CARGO_HOME=/usr/local/share/cargo \
    && cd /tmp && mise install --system \
    && ln -sf /usr/local/share/mise/installs/just/latest/just /usr/local/bin/just \
    && ln -sf "$RUSTUP_HOME"/toolchains/*/bin/cargo /usr/local/bin/cargo \
    && ln -sf "$RUSTUP_HOME"/toolchains/*/bin/rustc /usr/local/bin/rustc \
    && chmod -R a+rX /usr/local/share/mise /usr/local/share/rustup /usr/local/share/cargo

WORKDIR /cosmic-epoch
# PID 1 by default; a shell is one exec away.
CMD ["/sbin/init"]
