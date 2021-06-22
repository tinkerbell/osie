FROM python:3.9-alpine

ENTRYPOINT ["/entrypoint.sh"]
CMD ["python3", "run.py"]
VOLUME /statedir

WORKDIR /tmp
# runtime deps
RUN apk add --update --upgrade --no-cache \
        bash \
        docker \
        jq \
        libstdc++ \
    && \
# build time deps
    apk add --update --upgrade --no-cache --virtual build-deps \
        alpine-sdk \
        linux-headers \
        python3-dev \
        ;

COPY requirements.txt .
RUN pip install -r requirements.txt && \
    python3 -m pip uninstall -y pip && \
    apk del build-deps && \
    rm -rf /tmp/* $HOME/.cache

WORKDIR /
ADD entrypoint.sh *.py /

ARG GITVERSION
ARG GITBRANCH
ARG DRONEBUILD
ENV OSIE_VERSION=${GITVERSION} OSIE_BRANCH=${GITBRANCH} DRONE_BUILD=${DRONEBUILD}
