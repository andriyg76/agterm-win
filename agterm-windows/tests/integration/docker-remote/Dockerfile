# The docker-remote case's Linux remote: Ubuntu LTS with systemd as pid 1 and a lingering user manager, since
# agterm-server runs only as a systemd user unit (install.sh needs systemctl --user and loginctl).
# dbus carries logind, which starts the lingering user's manager; libpam-systemd gives that manager its XDG_RUNTIME_DIR.
# python3 serves the loopback page the case probes.
FROM ubuntu:24.04
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      systemd systemd-sysv dbus libpam-systemd procps python3 >/dev/null \
    && rm -rf /var/lib/apt/lists/*
# a fixed uid, since the remote's command names /run/user/<uid>; lingering is set as an administrator would
RUN useradd -m -u 2000 -s /bin/bash agterm && mkdir -p /var/lib/systemd/linger && touch /var/lib/systemd/linger/agterm
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
