ARG DEBIAN_VERSION=12
FROM debian:${DEBIAN_VERSION}-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg procps kmod systemd iproute2 shellcheck \
    initramfs-tools grub-common grub2-common python3 libpam-modules jq \
    && rm -rf /var/lib/apt/lists/*
COPY . /src
WORKDIR /src
CMD ["bash", "tests/integration.sh"]
