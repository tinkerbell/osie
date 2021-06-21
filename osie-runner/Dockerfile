FROM python:3.9-alpine

ENTRYPOINT ["/entrypoint.sh"]
CMD ["python3", "run.py"]
VOLUME /statedir

WORKDIR /tmp
COPY requirements.txt .
RUN apk update && apk add --update --upgrade --no-cache \
           bash \
           curl \
           alpine-sdk \
           docker \
           jq \
           libstdc++ \
           linux-headers \
           python3-dev
# Latest version is ok/on purpose
RUN  pip install -r requirements.txt  \
    &&  python3 -m pip uninstall -y pip \
    && apk del alpine-sdk linux-headers python3-dev \
    && rm -rf /tmp/* $HOME/.cache
WORKDIR /

ADD entrypoint.sh *.py /

ARG GITVERSION
ARG GITBRANCH
ARG DRONEBUILD
ENV OSIE_VERSION=${GITVERSION} OSIE_BRANCH=${GITBRANCH} DRONE_BUILD=${DRONEBUILD}
