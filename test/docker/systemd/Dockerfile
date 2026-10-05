# systemd's own word on the units connector writes (systemd-analyze verify),
# on the CNC's distro. BASE is the pinned ubuntu (test/helpers.bash). Apart
# from the node's image, so no other test runs where systemd is installed.
ARG BASE
FROM ${BASE}
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends systemd \
    && rm -rf /var/lib/apt/lists/*
