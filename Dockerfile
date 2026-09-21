# Isolated runtime for the conahcnuj driver.
#
# This image packages everything the driver needs (bash, git, curl, openssl,
# opencode and the driver itself) so that an autonomous run is confined to a
# container instead of the host machine.
#
# It does NOT bake in any secret: the GitHub App private key and app.env are
# bind-mounted at run time by docker-run.sh.
#
# Build:
#   docker build -t conahcnuj-runner .
# Run (prefer the wrapper, which handles the mounts):
#   bash docker-run.sh <issue-or-pr-number> [--pr]

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/root/.opencode/bin:/root/.local/bin:${PATH}"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        coreutils \
        curl \
        gawk \
        git \
        grep \
        openssl \
        sed \
        tar \
        unzip \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

# opencode, installed the same way CI does (free models need no API key).
RUN curl -fsSL https://opencode.ai/install | bash

# The driver, its libraries and the gh-app scripts. Layout mirrors the repo so
# the driver resolves ../lib and ../gh-app relative to /opt/conahcnuj/bin.
COPY bin/ /opt/conahcnuj/bin/
COPY lib/ /opt/conahcnuj/lib/
COPY gh-app/ /opt/conahcnuj/gh-app/

# The work tree is bind-mounted from the host; git would otherwise refuse it
# as "dubious ownership". The container is disposable, so trust everything.
RUN git config --global --add safe.directory '*'

WORKDIR /work
ENTRYPOINT ["/opt/conahcnuj/bin/conahcnuj.sh"]
