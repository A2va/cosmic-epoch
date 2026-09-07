FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive
ENV DE_COMPONENTS="cosmic-comp cosmic-session cosmic-panel cosmic-applets cosmic-launcher pop-launcher cosmic-icons cosmic-workspaces-epoch cosmic-settings-daemon cosmic-notifications cosmic-bg"
ENV DM_COMPONENTS="$DE_COMPONENTS cosmic-greeter"

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
      bsdextrautils \
      gtk-update-icon-cache hicolor-icon-theme \
      pipewire pipewire-bin \
      fonts-dejavu-core wl-clipboard \
 && rm -rf /var/lib/apt/lists/*

# noble ships an 'ubuntu' user with uid 1000; rename it instead of adding another.
# Password 'cosmic' for the greeter login (inside-dm's DM_PASSWORD overrides).
# -c SHA512: chpasswd defaults to yescrypt, whose ~16MB hashing buffer can't
# mmap inside greetd's mlockall()ed session worker (8MB RLIMIT_MEMLOCK here),
# so pam_unix would reject EVERY password. SHA512 verifies with no big alloc.
RUN usermod -l dev -d /home/dev -m ubuntu \
 && groupmod -n dev ubuntu \
 && echo 'dev ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/dev \
 && echo 'dev:cosmic' | chpasswd -c SHA512

# greetd's deb enables itself as display-manager.service; it would crash-loop
# at boot (no kernel VTs in a container). The display-manager alias is pointed
# at cosmic-greeter.service below instead (units ship with the greeter install).
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

# --- Static session config: everything inside-de/inside-dm need that does ---
# --- not depend on the mounted repo or the host display. --------------------
# Task caps: a cosmic session's panel + ~19 applets share one scope and burst
# past the stock DefaultTasksMax (307) and user-UID.slice TasksMax (675),
# failing thread spawn with EAGAIN. The user-.slice drop-in is on the
# template so it applies no matter when the slice first appears.
# dev's user manager must be up before any session starts (inside-de waits
# for its bus); linger at boot instead of a runtime enable-linger race.
RUN install -d /etc/systemd/system/user-.slice.d /etc/systemd/user.conf.d \
 && printf '[Slice]\nTasksMax=4096\n' > /etc/systemd/system/user-.slice.d/10-tasks.conf \
 && printf '[Manager]\nDefaultTasksMax=4096\n' > /etc/systemd/user.conf.d/10-tasks.conf \
 && mkdir -p /var/lib/systemd/linger && touch /var/lib/systemd/linger/dev

# greetd greeter session, static parts (the per-run host display is appended
# to /etc/environment by inside-dm.sh and read from there by pam_env):
#  - /etc/greetd/cosmic-greeter.toml: the repo's config with vt="none"
#    (containers have no kernel VTs) and an absolute command path.
#  - /usr/local/bin/cosmic-greeter-start: stock script plus log capture.
#  - /etc/pam.d/greetd-greeter: greetd's session worker mlockall()s, and in
#    this rootless container the 8MB RLIMIT_MEMLOCK is shared with every lib
#    PAM dlopens — the stock `@include login` stack no longer fits. Minimum
#    for a greeter: auth/account passthrough, pam_unix, pam_env (host
#    display for the greeter's cosmic-comp), pam_systemd (XDG_RUNTIME_DIR).
#  - /etc/pam.d/cosmic-greeter (user session): the deb's stack minus
#    pam_limits (its libsystemd is 2MB of memlock for nothing — ulimits come
#    from systemd units), pam_selinux (no-op without SELinux) and
#    pam_gnome_keyring (not installed; its faulty auth line fails every login).
#  - tmpfiles fragment: creates /run/cosmic-greeter (a11y state the greeter
#    and cosmic-settings-daemon share) at boot — normally shipped by the deb.
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
