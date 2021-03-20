FROM ubuntu:focal

VOLUME /statedir
ENTRYPOINT ["/entrypoint.sh"]

ARG GITVERSION
ARG GITBRANCH
ARG DRONEBUILD

ENV OSIE_VERSION ${GITVERSION}
ENV OSIE_BRANCH ${GITBRANCH}
ENV DRONE_BUILD ${DRONEBUILD}

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

# gron - grep for JSON
COPY lfs/gron-0.6.0-amd64 /tmp/osie/
RUN if [ $(uname -m) = 'x86_64' ]; then \
        mv /tmp/osie/gron-0.6.0-amd64 /usr/bin/gron; \
    fi && \
    rm -rf /tmp/osie

# build lshw, done here so we can keep it cached as long as possible
COPY build-lshw.sh /tmp/osie/
RUN apt-get update -y && \
    apt-get install -y build-essential && \
    (cd /tmp/osie/ && ./build-lshw.sh) && \
    apt-get -qy remove build-essential && \
    apt-get -qy autoremove && \
    apt-get -qy clean && \
    rm -rf /var/lib/apt/lists/* /tmp/osie/

# install mstflint, done here so we can keep it cached as long as possible
RUN if [ $(uname -m) = 'x86_64' ]; then \
    wget "http://archive.ubuntu.com/ubuntu/pool/universe/m/mstflint/mstflint_4.14.0+3-1_amd64.deb" && \
    apt-get update -y && \
    apt-get install -y ./mstflint_4.14.0+3-1_amd64.deb && \
    apt-get -qy autoremove && \
    apt-get -qy clean ; \
    fi && \
    rm -rf /var/lib/apt/lists/* /tmp/osie/

RUN if [ $(uname -m) = 'aarch64' ]; then \
    wget "http://ports.ubuntu.com/pool/universe/m/mstflint/mstflint_4.14.0+3-1_arm64.deb" && \
    apt-get update -y && \
    apt-get install -y ./mstflint_4.14.0+3-1_arm64.deb && \
    apt-get -qy autoremove && \
    apt-get -qy clean ; \
    fi && \
    rm -rf /var/lib/apt/lists/* /tmp/osie/

ARG PACKET_HARDWARE_COMMIT=68a25da2b6a3d3281838bff6b62639438116d0d1
ARG PACKET_NETWORKING_COMMIT=2c201b2da0563ca9363f78170663c0baa6054e32

RUN pip3 install git+https://github.com/packethost/packet-hardware.git@${PACKET_HARDWARE_COMMIT} && \
    pip3 install git+https://github.com/packethost/packet-networking.git@${PACKET_NETWORKING_COMMIT} && \
    rm -rf ~/.cache/pip*

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

# SSA CLI
RUN if [ $(uname -m) = 'x86_64' ]; then \
      temp="$(mktemp)" && \
      wget -O "$temp" 'https://downloads.linux.hpe.com/SDR/repo/mcp/pool/non-free/ssacli-4.17-6.0_amd64.deb' && \
      dpkg -i "$temp" && \
      rm -rf "$temp"; \
    fi ;

# IPMICFG
COPY lfs/ipmicfg /tmp/osie/
RUN cd /tmp/osie && \
    install -m 755 /tmp/osie/ipmicfg /usr/bin/ipmicfg && \
    rm -rf /tmp/osie

# RACADM
COPY dchipm.ini /tmp/osie/
RUN cd /tmp/osie && \
    if [ $(uname -m) != 'aarch64' ]; then \
      apt-get update && apt-get install -y alien && \
      rpm --import http://linux.dell.com/repo/pgp_pubkeys/0x1285491434D8786F.asc && \
      wget \
        https://dl.dell.com/FOLDER05920767M/1/DellEMC-iDRACTools-Web-LX-9.4.0-3732_A00.tar.gz \
        http://linux.dell.com/repo/community/openmanage/940/bionic/pool/main/s/srvadmin-omilcore/srvadmin-omilcore_9.4.0_amd64.deb && \
      tar -xvf DellEMC-iDRACTools-Web-LX-9.4.0-3732_A00.tar.gz && \
      alien -i iDRACTools/racadm/RHEL8/x86_64/*.rpm && \
      dpkg -i *.deb && \
      apt-get purge -y alien && \
      apt-get autoremove -y && \
      cp dchipm.ini /opt/dell/srvadmin/etc/srvadmin-hapi/ini/ ; \
    fi && \
    rm -rf /tmp/osie

# SuperMicro SUM
COPY lfs/sum_2.4.0_Linux_x86_64_20191206.tar.gz /tmp/osie/
RUN if [ $(uname -m) = 'x86_64' ]; then \
      mkdir -p /opt/supermicro && \
        tar -zxvf /tmp/osie/sum_2.4.0_Linux_x86_64_20191206.tar.gz -C /opt/supermicro && \
        ln -s /opt/supermicro/sum_2.4.0_Linux_x86_64 /opt/supermicro/sum; \
    fi ;

# URL=http://www.mellanox.com/downloads/firmware/mlxup
# VERSION=4.6.0
COPY lfs/mlxup-* /tmp/osie/
RUN install -m755 -D /tmp/osie/mlxup-$(uname -m) /opt/mellanox/mlxup && rm -rf /tmp/osie/

ARG ECLYPSIUM_AGENT_VERSION=2.0.0
ARG ECLYPSIUM_AGENT_SHA256=4bb5cfe3c6c3988b99c36e864f35abd8296120d197864a26f10a4c1868c9e31a
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

ARG METAL_BLOCK_STORAGE_COMMIT=95972b5a45a2c1be43dcb9288c551bee77557489
RUN curl --remote-name "https://raw.githubusercontent.com/packethost/metal-block-storage/$METAL_BLOCK_STORAGE_COMMIT/metal-block-storage-{attach,detach}" && \
    chmod +x /home/packet/metal-block-storage*

COPY entrypoint.sh /entrypoint.sh
COPY scripts/ /home/packet/

# ensure we always have up to date packages
RUN apt-get -y update && \
    apt-get -y dist-upgrade && \
    apt-get -y autoremove && \
    apt-get -y clean && \
    rm -rf /var/lib/apt/lists/* /home/packet/requirements.txt
