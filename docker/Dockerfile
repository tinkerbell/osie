FROM ubuntu:xenial

MAINTAINER David Laube <dlaube@packet.net>
LABEL Description="Ubuntu baremetal installation image" Vendor="Packet.net" Version="1.0"

VOLUME /statedir
ENTRYPOINT ["/entrypoint.sh"]

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

# apt sources fix
COPY sources.list.aarch64 /tmp/osie/
RUN if [ $(uname -m) = 'aarch64' ]; then \
        mv /tmp/osie/sources.list.aarch64 /etc/apt/sources.list; \
    fi && \
    rm -rf /tmp/osie

# runtime packages
COPY get-package-list.sh git-lfs-linux-*-v2.5.1-4-g2f166e02 /tmp/osie/
RUN apt-get update -y && \
    apt-get install -y $(/tmp/osie/get-package-list.sh) && \
    apt-get -qy autoremove && \
    apt-get -qy clean && \
    rm -rf /var/lib/apt/lists/* /tmp/osie

# build openssl'd git, done here so we can keep it cached as long as possible
COPY build-git-openssl.sh /tmp/osie/
RUN apt-get update -y && \
    /tmp/osie/build-git-openssl.sh && \
    dpkg --unpack /tmp/osie/git_*.deb /tmp/osie/git-core_*.deb /tmp/osie/git-man_*.deb && \
    apt-get install -f -y --no-install-recommends && \
    apt-get -y autoremove && \
    apt-get -y clean && \
    rm -rf /var/lib/apt/lists/* /tmp/osie

# build lshw, done here so we can keep it cached as long as possible
COPY build-lshw.sh /tmp/osie/
RUN apt-get update -y && \
    apt-get install -y build-essential && \
    (cd /tmp/osie/ && ./build-lshw.sh) && \
    apt-get -qy remove build-essential && \
    apt-get -qy autoremove && \
    apt-get -qy clean && \
    rm -rf /var/lib/apt/lists/* /tmp/osie/

# build nvme cli, done here so we can keep it cached as long as possible
COPY build-nvme-cli.sh /tmp/osie/
RUN apt-get update -y && \
    apt-get install -y build-essential && \
    (cd /tmp/osie/ && ./build-nvme-cli.sh) && \
    apt-get -qy remove build-essential && \
    apt-get -qy autoremove && \
    apt-get -qy clean && \
    rm -rf /var/lib/apt/lists/* /tmp/osie/

# build lxml, done here so we can keep it cached as long as possible
COPY scripts/requirements.txt /tmp/osie/
COPY scripts/packet-networking/ /tmp/osie/packet-networking/
RUN apt-get -qy update && \
    apt-get install -y \
      build-essential \
      libxml2-dev \
      libxslt1-dev \
      python3-dev \
      python3-pip \
      python3-setuptools \
      python3-wheel \
      zlib1g-dev && \
    pip3 install -r /tmp/osie/requirements.txt && \
    pip3 install --upgrade setuptools && \
    pip3 install /tmp/osie/packet-networking && \
    apt-get remove -y \
      build-essential \
      libxml2-dev \
      libxslt1-dev \
      python3-dev \
      python3-pip \
      python3-setuptools \
      python3-wheel \
      zlib1g-dev && \
    apt-get -qy autoremove && \
    apt-get -qy clean && \
    rm -rf /var/lib/apt/lists/* /tmp/osie ~/.cache/pip*

# static prebuilt git-lfs packages
COPY lfs/git-lfs-linux-*-v2.5.1-4-g2f166e02 /tmp/osie/
RUN mv /tmp/osie/git-lfs-linux-$(uname -m)-* /usr/bin/git-lfs && \
    chmod 755 /usr/bin/git-lfs && \
    git-lfs install && \
    rm -rf /tmp/osie

# LSI CLI
COPY lfs/megacli-noarch-bin.tar /tmp/osie/
RUN tar -xvC / -f /tmp/osie/megacli-noarch-bin.tar && \
    ln -nsf /opt/MegaRAID/MegaCli/MegaCli64 /usr/bin/ && \
    rm -rf /tmp/osie

# PERC CLI
COPY lfs/perccli-1.17.10-1.tar.gz /tmp/osie/
RUN tar -zxvC / -f /tmp/osie/perccli-1.17.10-1.tar.gz && \
    ln -nsf /opt/MegaRAID/perccli/perccli64 /usr/bin/ && \
    rm -rf /tmp/osie

# Marvell CLI
COPY lfs/mvcli-4.1.13.31_A01.zip /tmp/osie/
RUN cd /tmp/osie && \
    unzip mvcli-4.1.13.31_A01.zip && \
    cd mvcli-4.1.13.31_A01/x64/cli && \
    cp -f mvcli /usr/bin && \
    cp -f libmvraid.so /usr/lib && \
    chmod 755 /usr/bin/mvcli && \
    cd && \
    rm -r /tmp/osie

# URL=http://www.mellanox.com/downloads/firmware/mlxup
# VERSION=4.6.0
COPY lfs/mlxup-* /tmp/osie/
RUN install -m755 -D /tmp/osie/mlxup-$(uname -m) /opt/mellanox/mlxup && rm -rf /tmp/osie/

ARG ECLYPSIUM_AGENT_VERSION=1.5.3
ARG ECLYPSIUM_AGENT_SHA256=d80259fe0fc653f5395990329ed2882e202c24a680ed2cb4ce0be4a33676fc0c
ARG ECLYPSIUM_AGENT_FILENAME=eclypsiumapp-${ECLYPSIUM_AGENT_VERSION}.deb

COPY lfs/${ECLYPSIUM_AGENT_FILENAME} /tmp/
RUN if [ $(uname -m) = 'x86_64' ]; then \
        cd /tmp && \
        echo "${ECLYPSIUM_AGENT_SHA256}  ${ECLYPSIUM_AGENT_FILENAME}" | sha256sum -c && \
        dpkg --unpack "${ECLYPSIUM_AGENT_FILENAME}" && \
        sed -i 's/try_restart_service /#try_restart_service /g' /var/lib/dpkg/info/eclypsiumapp.postinst && \
        dpkg --configure eclypsiumapp && \
        rm -f "${ECLYPSIUM_AGENT_FILENAME}"; \
    fi ;

# freebsd ufs fs fuse
COPY lfs/osie-fuse-* /tmp/osie/
RUN mv /tmp/osie/osie-fuse*$(uname -m).deb /tmp/ && rm -rf /tmp/osie/

RUN useradd packet -d /home/packet -m -U && \
    chown -R packet:packet /home/packet
WORKDIR /home/packet

ADD https://raw.githubusercontent.com/packethost/packet-block-storage/master/packet-block-storage-attach \
    https://raw.githubusercontent.com/packethost/packet-block-storage/master/packet-block-storage-detach \
    /home/packet/

COPY entrypoint.sh /entrypoint.sh
COPY scripts/ /home/packet/

# ensure we always have up to date packages
RUN apt-get -y update && \
    apt-get -y dist-upgrade && \
    apt-get -y autoremove && \
    apt-get -y clean && \
    rm -rf /var/lib/apt/lists/* /home/packet/requirements.txt
