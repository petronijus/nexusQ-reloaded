FROM alpine:3.21

RUN apk add --no-cache \
    python3 py3-pip git sudo bash coreutils \
    openssl dtc patch diffutils findutils curl wget \
    multipath-tools util-linux losetup dos2unix

# PINNED, deliberately. This used to track pmbootstrap git master, which made the
# builder image's contents depend on the day it was built: on 2026-08-16 an image
# carrying 3.10.1 met a pmaports tree that had bumped
# `required_pmbootstrap_version` to 3.11.0 upstream, and EVERY build — OTA and
# full — died in Phase 7b with "Please update your pmbootstrap version".
# docker-build.sh pins pmaports to a matching commit for the same reason; bump
# the two together, deliberately, and re-verify the three pmbootstrap monkey
# patches (backend.py abuild-as-root, partition.py partitions_mount,
# blockdevice.py) still apply — they are load-bearing and only warn when they
# miss.
ARG PMBOOTSTRAP_REF=3.11.0
RUN pip3 install --break-system-packages \
    "git+https://gitlab.postmarketos.org/postmarketOS/pmbootstrap.git@${PMBOOTSTRAP_REF}" \
 && pmbootstrap --version

RUN adduser -D pmos && echo "pmos ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

RUN printf '#!/bin/bash\nSCRIPT="$1"; shift\nTMP=$(mktemp)\ntr -d "\\r" < "$SCRIPT" > "$TMP"\nexec bash "$TMP" "$@"\n' \
    > /usr/local/bin/entrypoint.sh && chmod +x /usr/local/bin/entrypoint.sh

USER pmos
WORKDIR /home/pmos

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
