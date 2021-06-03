FROM alpine:3.12

RUN apk add --no-cache --no-progress --update --upgrade \
        bash \
        bridge-utils \
        coreutils \
        cpio \
        curl \
        diffutils \
        dnsmasq \
        docker \
        eudev \
        file \
        findutils \
        gcc \
        git \
        go \
        gptfdisk \
        iptables \
        jq \
        libarchive-tools \
        make \
        musl-dev \
        ncurses \
        ovmf \
        pigz \
        py3-pip \
        python3 \
        python3-dev \
        qemu-system-aarch64 \
        qemu-system-x86_64 \
        rsync \
        socat \
        util-linux \
        && \
    mv /etc/apk/repositories /etc/apk/repositories.old && \
    apk add --no-cache --update --upgrade \
        --repository=http://dl-cdn.alpinelinux.org/alpine/v3.11/main \
        --repository=http://dl-cdn.alpinelinux.org/alpine/v3.11/community \
        lshw \
        && \
    mv /etc/apk/repositories.old /etc/apk/repositories && \
    apk add --no-cache --update --upgrade \
        --repository=http://dl-cdn.alpinelinux.org/alpine/edge/testing \
        cfssl \
   ;


COPY ./proxy /tmp/proxy/
RUN cd /tmp/proxy && \
    CGO_ENABLED=0 go build -v -tags "caddyserver0.9 caddyserver1.0"  -o /bin/proxy && \
    /bin/proxy --version # this is going to break if/when we update to go1.15 (maybe 1.14?), at that point HAProxy + lua upload service is probably the way to go

RUN mkdir $HOME/bin && \
    wget "https://dl.minio.io/client/mc/release/linux-amd64/mc" -O bin/mc && \
    chmod +x bin/mc

ENV PATH=$HOME/bin:$PATH

RUN curl -fL https://github.com/mvdan/sh/releases/download/v2.3.0/shfmt_v2.3.0_linux_amd64 >/bin/shfmt && \
    echo 'eef540565962cf1f5432c7e3cf212c333e096f9f481d6d441197c1cf878746d0 /bin/shfmt' | sha256sum -c && \
    chmod +x /bin/shfmt

RUN pip3 install click j2cli packet-python==1.38.2 && \
    pip3 install coverage

RUN curl -L https://github.com/git-lfs/git-lfs/releases/download/v2.5.1/git-lfs-linux-amd64-v2.5.1.tar.gz >/tmp/git-lfs.tar.gz && \
    echo '9565fa9c2442c3982567a3498c9352cda88e0f6a982648054de0440e273749e7  /tmp/git-lfs.tar.gz' | sha256sum -c && \
    tar -zxf /tmp/git-lfs.tar.gz -C /usr/bin git-lfs && \
    git-lfs install

COPY tls/ /tls/
ENV TERM=xterm-256color
