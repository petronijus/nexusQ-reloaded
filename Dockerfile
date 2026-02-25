FROM alpine:3.21

RUN apk add --no-cache \
    python3 py3-pip git sudo bash coreutils \
    openssl dtc patch diffutils findutils curl wget \
    multipath-tools util-linux losetup

RUN pip3 install --break-system-packages \
    git+https://gitlab.postmarketos.org/postmarketOS/pmbootstrap.git

RUN adduser -D pmos && echo "pmos ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

USER pmos
WORKDIR /home/pmos

ENTRYPOINT ["/bin/bash"]
