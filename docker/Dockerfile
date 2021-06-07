FROM ubuntu:xenial as builder
RUN apt-get update -y && apt-get install -y build-essential curl

FROM builder as lshw
COPY build-lshw.sh /tmp/osie/build.sh
RUN cd /tmp/osie/ && DESTDIR=/tmp/out ./build.sh

FROM builder as nvme
COPY build-nvme-cli.sh /tmp/osie/build.sh
RUN cd /tmp/osie/ && DESTDIR=/tmp/out ./build.sh

FROM builder as mstflint
COPY build-mstflint.sh /tmp/osie/build.sh
RUN cd /tmp/osie/ && DESTDIR=/tmp/out ./build.sh

FROM builder as smartmontools
COPY build-smartmontools.sh /tmp/osie/build.sh
RUN cd /tmp/osie/ && DESTDIR=/tmp/out ./build.sh

FROM builder as racadm
RUN apt-get update && apt-get install -y alien wget
RUN rpm --verbose --import https://linux.dell.com/repo/pgp_pubkeys/0x1285491434D8786F.asc
WORKDIR /tmp/osie
RUN wget \
        https://dl.dell.com/FOLDER05920767M/1/DellEMC-iDRACTools-Web-LX-9.4.0-3732_A00.tar.gz \
        http://linux.dell.com/repo/community/openmanage/940/bionic/pool/main/s/srvadmin-omilcore/srvadmin-omilcore_9.4.0_amd64.deb
RUN tar -xvf DellEMC-iDRACTools-Web-LX-9.4.0-3732_A00.tar.gz
RUN if [ $(uname -m) = 'x86_64' ]; then \
      alien iDRACTools/racadm/RHEL8/x86_64/*.rpm && install -D --mode=0644 --target-directory=/tmp/out *.deb; \
    else \
      mkdir /tmp/out && touch /tmp/out/not-really-a.deb; \
    fi

FROM ubuntu:xenial as final

VOLUME /statedir
ENTRYPOINT ["/entrypoint.sh"]

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

# runtime packages
COPY get-package-list.sh /tmp/osie/
RUN apt-get update -y && apt-get install -y $(/tmp/osie/get-package-list.sh)
RUN apt-get -qy autoremove
RUN apt-get -qy clean
RUN rm -rf /var/lib/apt/lists/* /tmp/osie

# gron - grep for JSON
COPY lfs/gron-0.6.0-amd64 /tmp/osie/
RUN if [ $(uname -m) = 'x86_64' ]; then \
        mv /tmp/osie/gron-0.6.0-amd64 /usr/bin/gron; \
    fi && \
    rm -rf /tmp/osie

ARG PACKET_HARDWARE_COMMIT=68a25da2b6a3d3281838bff6b62639438116d0d1
ARG PACKET_NETWORKING_COMMIT=06061801efaf34caa8d8b1ae5973c15e5a23659d

RUN curl https://bootstrap.pypa.io/pip/3.5/get-pip.py | python3
RUN pip3 install git+https://github.com/packethost/packet-hardware.git@${PACKET_HARDWARE_COMMIT}
RUN pip3 install git+https://github.com/packethost/packet-networking.git@${PACKET_NETWORKING_COMMIT}
RUN rm -rf ~/.cache/pip*

# static prebuilt git-lfs packages
COPY lfs/git-lfs-linux-*-v2.5.1-4-g2f166e02 /tmp/osie/
RUN mv /tmp/osie/git-lfs-linux-$(uname -m)-* /usr/bin/git-lfs
RUN chmod 755 /usr/bin/git-lfs
RUN git-lfs install
RUN rm -rf /tmp/osie

# LSI CLI
COPY lfs/megacli-noarch-bin.tar /tmp/osie/
RUN tar -xvC / -f /tmp/osie/megacli-noarch-bin.tar
RUN ln -nsf /opt/MegaRAID/MegaCli/MegaCli64 /usr/bin/
RUN rm -rf /tmp/osie

# PERC CLI
COPY lfs/perccli-1.17.10-1.tar.gz /tmp/osie/
RUN tar -zxvC / -f /tmp/osie/perccli-1.17.10-1.tar.gz
RUN ln -nsf /opt/MegaRAID/perccli/perccli64 /usr/bin/

# Marvell CLI
COPY lfs/mvcli-4.1.13.31_A01.zip /tmp/osie/
WORKDIR /tmp/osie
RUN unzip mvcli-4.1.13.31_A01.zip
RUN install -m0755 mvcli-4.1.13.31_A01/x64/cli/mvcli /usr/bin
RUN cp -f mvcli-4.1.13.31_A01/x64/cli/libmvraid.so /usr/lib
WORKDIR /
RUN rm -r /tmp/osie

# SSA CLI
RUN if [ $(uname -m) = 'x86_64' ]; then \
      temp="$(mktemp)" && \
      wget -O "$temp" 'https://downloads.linux.hpe.com/SDR/repo/mcp/pool/non-free/ssacli-4.17-6.0_amd64.deb' && \
      dpkg -i "$temp" && \
      rm -rf "$temp"; \
    fi ;

# IPMICFG
COPY lfs/ipmicfg /tmp/osie/
RUN install -m 755 /tmp/osie/ipmicfg /usr/bin/ipmicfg
RUN rm -rf /tmp/osie

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
RUN install -m755 -D /tmp/osie/mlxup-$(uname -m) /opt/mellanox/mlxup
RUN rm -rf /tmp/osie/

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
RUN mv /tmp/osie/osie-fuse*$(uname -m).deb /tmp/
RUN rm -rf /tmp/osie/

RUN useradd packet -d /home/packet -m -U
RUN chown -R packet:packet /home/packet
WORKDIR /home/packet

ARG METAL_BLOCK_STORAGE_COMMIT=95972b5a45a2c1be43dcb9288c551bee77557489
RUN curl --remote-name "https://raw.githubusercontent.com/packethost/metal-block-storage/$METAL_BLOCK_STORAGE_COMMIT/metal-block-storage-{attach,detach}"
RUN chmod +x /home/packet/metal-block-storage*

COPY entrypoint.sh /entrypoint.sh
COPY scripts/ /home/packet/

COPY --from=lshw /tmp/out/ /
RUN lshw --help

COPY --from=nvme /tmp/out/ /
RUN nvme --help

COPY --from=mstflint /tmp/out/ /
RUN mstflint --help

COPY --from=smartmontools /tmp/out/ /
RUN smartctl --help

COPY --from=racadm /tmp/out/*.deb /tmp/osie/
RUN if [ $(uname -m) = x86_64 ]; then dpkg -i /tmp/osie/*.deb && /opt/dell/srvadmin/bin/idracadm7; fi
COPY dchipm.ini /opt/dell/srvadmin/etc/srvadmin-hapi/ini/

ARG GITVERSION
ARG GITBRANCH
ARG DRONEBUILD
ENV OSIE_VERSION=${GITVERSION} OSIE_BRANCH=${GITBRANCH} DRONE_BUILD=${DRONEBUILD}

# ensure we always have up to date packages
RUN apt-get -y update && apt-get -y dist-upgrade
RUN apt-get -y autoremove
RUN apt-get -y clean
RUN rm -rf /var/lib/apt/lists/* /home/packet/requirements.txt
