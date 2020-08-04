FROM alpine:3.7

ENTRYPOINT [ "/build.sh" ]
VOLUME /assets

RUN mkdir -p /etc/apk/cache && \
    apk add --update --upgrade \
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
        && \
    apk add --no-scripts --update --upgrade --repository http://dl-cdn.alpinelinux.org/alpine/edge/testing \
        kexec-tools \
        && \
    apk cache sync && \
    mv /etc/apk/cache /cache && \
    apk add --no-scripts --no-cache --update --upgrade \
        abuild \
        alpine-sdk \
        build-base \
        busybox-initscripts \
        coreutils \
        linux-headers \
        sudo \
        && \
    # remove edge when linux-vanilla is > 4.14.8 and has the nfp driver enabled,
    # likely alpine v3.8
    apk add --no-scripts --no-cache --update --upgrade --repository http://dl-cdn.alpinelinux.org/alpine/edge/main \
        linux-firmware \
	&& \
    adduser -G abuild -g "Alpine Package Builder" -s /bin/ash -D builder && \
    echo "builder ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers && \
    apk update

USER builder
WORKDIR /home/builder

ENV COMMIT bb52b0d3f60cd75197ef218362f193378dfd869d
ENV FLAVOR vanilla
ENV KERNEL 4.14.55
# make sure PKGREL is +1 what is in APKGBUILD
ENV PKGREL 1

RUN true && \
    # Setup self-signed keys to sign the built packages \
    abuild-keygen -a -i -n && \
    # Fetch alpine package tree \
    curl -fL https://github.com/alpinelinux/aports/archive/$COMMIT.tar.gz | tar -zxf - && \
    mv aports-$COMMIT aports && \
    # Build customized linux-$FLAVOR package \
    cd aports/main/linux-$FLAVOR && \
    sed -i APKBUILD \
        -e 's/silentoldconfig/olddefconfig/g' \
	-e "/^pkgrel=/ s/=.*/=$PKGREL/" && \
    # we only want to build the config-$FLAVOR.x86_64 kernel, so we need remove to any lines that look like config.*x86_64 but is not config-$FLAVOR.x86_46 \
    # explanation: \
    #   /config.*x86_64/! p       :: if line does *not* match config.*x86_64 (on account of the trailing ! after /.../) print it \
    #   /config.*x86_64/ { ... }  :: apply sub expression only for lines that match the pattern (so everything not ^) \
    #   /config-$FLAVOR.x86_64/ p :: print the config-$FLAVOR.x86_64 lines \
    sed -i APKBUILD -n \
        -e '/config.*x86_64/! p; /config.*x86_64/ { /config-'$FLAVOR'.x86_64/ p }' && \
    echo 'CONFIG_KEXEC=y' >> config-$FLAVOR.x86_64 && \
    abuild checksum && \
    MAKEFLAGS=-j$(nproc) abuild -r && \
    abuild clean && \
    # Install the customized linux-vanilla package
    sudo apk add --no-scripts --update --upgrade /home/builder/packages/main/x86_64/linux-$FLAVOR*.apk

ARG ECLYPSIUM_DRIVER_VERSION=2.0.0
ARG ECLYPSIUM_DRIVER_SHA512=b9cfebc3b0abd834d73f025f925d896bea8d9dac2a3c3605980a94a35cd188db159ca165e5884863f5bd4a94d39861ecdf998cf8e99ea89d6f093a7bc64b5347
ARG ECLYPSIUM_DRIVER_FILENAME=eclypsiumdriver-alpine-${ECLYPSIUM_DRIVER_VERSION}.tgz

COPY ${ECLYPSIUM_DRIVER_FILENAME} /home/builder/

# Download the eclypsium driver abuild and build it
RUN echo "${ECLYPSIUM_DRIVER_SHA512}  ${ECLYPSIUM_DRIVER_FILENAME}" | sha512sum -c && \
    tar -zxvf ${ECLYPSIUM_DRIVER_FILENAME} && \
    cd aports/non-free/eclypsiumdriver && \
    sed -i APKBUILD \
        -e "/^_kver=/    s/=.*/=$KERNEL/" \
        -e "/^_kpkgrel=/ s/=.*/=$PKGREL/" \
        && \
    abuild checksum && \
    MAKEFLAGS=-j$(nproc) abuild -r && \
    abuild clean && \
    sudo apk add --no-scripts --no-cache --update --upgrade /home/builder/packages/non-free/x86_64/eclypsium*.apk

USER root
RUN sudo mv /cache /etc/apk/cache

COPY build.sh /build.sh
