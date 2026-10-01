# A Linux machine for connector to run on as root, in the docker tier: a CNC
# or a node, with what one has -- the CA store and its tools, openssl, jq,
# sqlite3 and age. BASE is the pinned ubuntu (test/helpers.bash).
ARG BASE
FROM ${BASE}
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates openssl jq sqlite3 age iproute2 \
    && rm -rf /var/lib/apt/lists/*
