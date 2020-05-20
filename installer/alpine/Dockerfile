FROM alpine:3.7

ENTRYPOINT /build.sh
VOLUME /assets

COPY qemu-aarch64-static /usr/bin/

RUN mkdir -p /etc/apk/cache
RUN apk add --update --upgrade \
    alpine-base \
    curl \
    docker \
    jq \
    mdadm \
    mkinitfs \
    musl-utils \
    openssh \
    squashfs-tools \
    tcpdump \
    ;
RUN apk cache sync
RUN mv /etc/apk/cache /cache
RUN apk add --no-scripts --no-cache --update --upgrade \
    abuild \
    alpine-sdk \
    build-base \
    busybox-initscripts \
    coreutils \
    linux-headers \
    ;

# remove edge when linux-vanilla is > 4.14.8 and has the nfp driver enabled,
# likely alpine v3.8
RUN apk add --no-scripts --no-cache --update --upgrade --repository http://dl-cdn.alpinelinux.org/alpine/edge/main \
    linux-firmware \
    ;

RUN adduser -G abuild -g "Alpine Package Builder" -s /bin/ash -D builder && \
    echo "builder ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers && \
    apk update

USER builder
WORKDIR /home/builder

# Setup some self-signed keys and grab alpine package tree
RUN abuild-keygen -a -i -n && \
    git clone -b master https://github.com/alpinelinux/aports && \
    cd aports && \
    git checkout bb52b0d3f60cd75197ef218362f193378dfd869d

# Build customized linux-vanilla
WORKDIR /home/builder/aports/main/linux-vanilla

RUN sed -i 's/silentoldconfig/olddefconfig/g' APKBUILD && \
    echo 'CONFIG_KEXEC=y' >> config-vanilla.x86_64 && \
    abuild checksum && \
    abuild -r && \
    abuild clean

USER root
# RUN apk add --no-scripts --no-cache --update --upgrade /home/builder/packages/main/x86_64/linux-vanilla*.apk
RUN apk add --no-scripts --update --upgrade /home/builder/packages/main/x86_64/linux-vanilla*.apk

# ADD https://www.kernel.org/pub/linux/utils/kernel/kexec/kexec-tools-2.0.17.tar.gz .

# RUN zcat kexec-tools-2.0.17.tar.gz | tar xvf - && \
#   cd kexec-tools-2.0.17 && \
#   sed 's/loff_t/off_t/g' -i vmcore-dmesg/vmcore-dmesg.c && \
#   ./configure && \
#   make && \
#   make install

ARG ECLYPSIUM_DRIVER_VERSION=2.0.0
ARG ECLYPSIUM_DRIVER_SHA512=b9cfebc3b0abd834d73f025f925d896bea8d9dac2a3c3605980a94a35cd188db159ca165e5884863f5bd4a94d39861ecdf998cf8e99ea89d6f093a7bc64b5347
ARG ECLYPSIUM_DRIVER_FILENAME=eclypsiumdriver-alpine-${ECLYPSIUM_DRIVER_VERSION}.tgz

COPY ${ECLYPSIUM_DRIVER_FILENAME} /home/builder/
USER builder
WORKDIR /home/builder

ENV FLAVOR vanilla
# Download the eclypsium driver abuild and build it
# we force it to build for a vanilla kernel of a specific version with the sed(s) below
# sed -i 's/4\.9\.65/4.14.34/g' APKBUILD && \
# sed -i 's/\tmake/make kernel-src-dir="\/lib\/modules\/4.14.34-0-vanilla\/build" machine="x86_64"/' APKBUILD && \
RUN echo "${ECLYPSIUM_DRIVER_SHA512}  ${ECLYPSIUM_DRIVER_FILENAME}" | sha512sum -c && \
    tar -zxvf ${ECLYPSIUM_DRIVER_FILENAME} && \
    cd aports/non-free/eclypsiumdriver && \
    sed -i 's/_kpkgrel=1/_kpkgrel=0/' APKBUILD && \
    sed -i 's/5\.4\.12/4.14.55/g' APKBUILD && \
    abuild checksum && \
    abuild -r

USER root

RUN mv /cache /etc/apk/cache

RUN apk add --no-scripts --update --upgrade --repository http://dl-cdn.alpinelinux.org/alpine/edge/testing kexec-tools

COPY build.sh /build.sh
