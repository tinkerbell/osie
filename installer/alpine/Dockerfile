FROM alpine:3.12

ENTRYPOINT [ "/build.sh" ]
VOLUME /assets

RUN true && \
    # Setup a cache dir so apk will cache the apks
    mkdir -p /etc/apk/cache && \
    apk add --update --upgrade \
        alpine-base \
        curl \
        docker \
        jq \
        linux-firmware \
        mdadm \
        mkinitfs \
        musl-utils \
        openssh \
        squashfs-tools \
        tcpdump \
        && \
    # A cache sync ensure all the deps are cached, even if the dep was pre-installed already and thus not needed to be fetched
    apk cache sync && \
    apk add --no-scripts --no-cache --update --upgrade --cache-dir /tmp/non-persisted-apk-cache-dir \
        abuild \
        alpine-sdk \
        build-base \
        busybox-initscripts \
        coreutils \
        linux-headers \
        sudo \
        unzip \
        && \
    adduser -G abuild -g "Alpine Package Builder" -s /bin/ash -D builder && \
    echo "builder ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers && \
    apk update

USER builder
WORKDIR /home/builder

ENV COMMIT 69b95a3d1dd1627416f45bcbfb93c6f2d5f0d68b
ENV FLAVOR lts
ENV KERNEL 5.4.52
# make sure PKGREL is +1 what is in APKGBUILD
ENV PKGREL 1

# Setup self-signed keys to sign the built packages
RUN abuild-keygen -a -i -n && \
    # Fetch alpine package tree \
    curl -fL https://github.com/alpinelinux/aports/archive/$COMMIT.tar.gz | tar -zxf - && \
    mv aports-$COMMIT aports

# Install customized linux-$FLAVOR package \
RUN cd aports/main/linux-$FLAVOR && \
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
    echo 'CONFIG_IONIC=y' >> config-$FLAVOR.x86_64 && \
    abuild checksum && \
    MAKEFLAGS=-j$(nproc) abuild -r && \
    abuild clean && \
    sudo apk add --no-scripts --no-cache --update --upgrade --cache-dir /tmp/non-persisted-apk-cache-dir \
        /home/builder/packages/main/x86_64/linux-$FLAVOR*.apk

ARG ECLYPSIUM_DRIVER_VERSION=2.5.2
ARG ECLYPSIUM_DRIVER_SHA512=574620d7077663c5034eb2a3670732cb445067292ec146070715700cd9b319979e302adee885468856f87a6b457f0c7aef47352e19fe7348fa6be74966a4dcbe
ARG ECLYPSIUM_DRIVER_FILENAME=eclypsiumdriver-alpine-${ECLYPSIUM_DRIVER_VERSION}.tgz

COPY ${ECLYPSIUM_DRIVER_FILENAME} /home/builder/

# Install the eclypsium driver
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
    sudo apk add --no-scripts --no-cache --update --upgrade --cache-dir /tmp/non-persisted-apk-cache-dir \
        /home/builder/packages/non-free/x86_64/eclypsium*.apk

# Build and install the ASRR BIOS utility and kernel module
ARG ASRR_BIOS_DRIVER_VERSION=1.0
ARG ASRR_BIOS_DRIVER_SHA512=5dbb458dd105d872f61f0256ec1a57c5de922328a23cd42e636b35c5bbda7e1e1d957b271de76b49345c35a55a97845842de106aea61f930ac440ad6e21f344a
ARG ASRR_BIOS_DRIVER_FILENAME="BIOSControl_v1.0.3.zip"

COPY ${ASRR_BIOS_DRIVER_FILENAME} /home/builder/
RUN echo "${ASRR_BIOS_DRIVER_SHA512} ${ASRR_BIOS_DRIVER_FILENAME}" | sha512sum -c && \
    unzip ${ASRR_BIOS_DRIVER_FILENAME} && \
    # def for 5.x kernel build
    echo '#define LINUX_VERSION_500 0' > driver/ver.h && \
    # build module
    make -C /lib/modules/${KERNEL}-${PKGREL}-${FLAVOR}/build M=/home/builder/driver && \
    # install module
    sudo install -D -m 600 driver/asrdev.ko /lib/modules/${KERNEL}-${PKGREL}-${FLAVOR}/extra/ && \
    # clean up
    rm -rf /home/builder/BIOSControl /home/builder/driver /home/builder/ReadMe.txt

# Remove built and installed packages, these never get installed at runtime
RUN rm -rf /home/builder/packages/*


# Build packages we want to install at osie runtime from this aports checkout #
###############################################################################

# Build pinned kexec-tools package
RUN cd aports/testing/kexec-tools && \
    abuild checksum && \
    MAKEFLAGS=-j$(nproc) abuild -r && \
    abuild clean

USER root
RUN true && \
    # Setup our own repos
    mkdir -p /etc/apk/repos && \
    cp -a /home/builder/packages/* /etc/apk/repos && \
    # Clear out installed file since it was empty before
    truncate -s0 /etc/apk/cache/installed

COPY build.sh /build.sh
