FROM alpine:3.12 AS needs-squashing

ENTRYPOINT ["/entrypoint.sh"]
CMD ["python3", "run.py"]
VOLUME /statedir

ARG GITVERSION
ARG GITBRANCH
ARG DRONEBUILD

ENV OSIE_VERSION ${GITVERSION}
ENV OSIE_BRANCH ${GITBRANCH}
ENV DRONE_BUILD ${DRONEBUILD}

WORKDIR /tmp
RUN apk add --update --upgrade --no-cache bash docker jq libstdc++ python3
COPY requirements.txt .
RUN apk add --update --upgrade --no-cache --virtual build-deps alpine-sdk curl linux-headers python3-dev && \
    # Latest version is ok/on purpose
    curl -sSL https://bootstrap.pypa.io/get-pip.py -o get-pip.py && \
    python3 get-pip.py && \
    pip install -r requirements.txt && \
    yes y | python3 -m pip uninstall pip && \
    apk del build-deps && \
    rm -rf /tmp/* $HOME/.cache 

RUN rm -vfr \
    /tmp/* \
    /var/tmp/* \
    /var/lib/apt/lists/*

WORKDIR /

ADD entrypoint.sh *.py /

FROM scratch
COPY --from=needs-squashing / /
