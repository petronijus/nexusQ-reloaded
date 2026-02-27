FROM alpine:3.21

RUN apk add --no-cache \
    python3 py3-pip git sudo bash coreutils \
    openssl dtc patch diffutils findutils curl wget \
    multipath-tools util-linux losetup dos2unix

RUN pip3 install --break-system-packages \
    git+https://gitlab.postmarketos.org/postmarketOS/pmbootstrap.git

RUN adduser -D pmos && echo "pmos ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

RUN printf '#!/bin/bash\nSCRIPT="$1"; shift\nTMP=$(mktemp)\ntr -d "\\r" < "$SCRIPT" > "$TMP"\nexec bash "$TMP" "$@"\n' \
    > /usr/local/bin/entrypoint.sh && chmod +x /usr/local/bin/entrypoint.sh

USER pmos
WORKDIR /home/pmos

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
