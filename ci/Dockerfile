# vim: set expandtab shiftwidth=4 softtabstop=4:
FROM alpine:3.10

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
    git \
    go \
    gptfdisk \
    iptables \
    jq \
    libarchive-tools \
    lshw \
    make \
    musl-dev \
    ovmf \
    pigz \
    py2-pip \
    qemu-system-aarch64 \
    qemu-system-x86_64 \
    rsync \
    socat \
    util-linux \
    python3 \
    python3-dev \
    gcc \
    && apk add --no-cache --update --upgrade \
        --repository=http://dl-cdn.alpinelinux.org/alpine/edge/testing \
        cfssl \
   ;


RUN git clone -b v0.10.11 https://github.com/mholt/caddy /root/go/src/github.com/mholt/caddy && \
    git clone https://github.com/wmark/go.abs /root/go/src/plugin.hosting/go/abs && (cd /root/go/src/plugin.hosting/go/abs && git checkout 1ba06a13d0c0530cb12338dd83254ececc6e509f) && \
    git clone -b v1.3.2 https://github.com/wmark/caddy.upload /root/go/src/blitznote.com/src/caddy.upload && \
    cd /root/go/src/blitznote.com/src/caddy.upload && go get -v && \
    cd /root/go/src/github.com/mholt/caddy/caddy && sed -i -e '/This is where other plugins/a \\t_ "blitznote.com/src/caddy.upload"' caddymain/run.go && \
    CGO_ENABLED=0 go build -v -o /bin/caddy

RUN mkdir $HOME/bin && \
    wget "https://dl.minio.io/client/mc/release/linux-amd64/mc" -O bin/mc && \
    chmod +x bin/mc

ENV PATH=$HOME/bin:$PATH

RUN curl -fL https://github.com/mvdan/sh/releases/download/v2.3.0/shfmt_v2.3.0_linux_amd64 >/bin/shfmt && \
    echo 'eef540565962cf1f5432c7e3cf212c333e096f9f481d6d441197c1cf878746d0 /bin/shfmt' | sha256sum -c && \
    chmod +x /bin/shfmt

RUN pip install click jinja2-cli packet-python==1.38.2 && \
    pip3 install click jinja2-cli packet-python==1.38.2 && \
    pip3 install coverage

RUN curl -L https://github.com/git-lfs/git-lfs/releases/download/v2.5.1/git-lfs-linux-amd64-v2.5.1.tar.gz >/tmp/git-lfs.tar.gz && \
    echo '9565fa9c2442c3982567a3498c9352cda88e0f6a982648054de0440e273749e7  /tmp/git-lfs.tar.gz' | sha256sum -c && \
    tar -zxf /tmp/git-lfs.tar.gz -C /usr/bin git-lfs && \
    git-lfs install

COPY tls/ /tls/
