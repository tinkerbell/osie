FROM python:3.5-alpine3.12

ENTRYPOINT ["/entrypoint.sh"]
CMD ["python3", "run.py"]
VOLUME /statedir

WORKDIR /tmp
COPY requirements.txt .
RUN apk add --update --upgrade --no-cache --virtual \
           alpine-sdk \
           bash \
           build-deps \
           curl \
           docker \
           jq \
           libstdc++ \
           linux-headers \
           python3-dev  \
    # Latest version is ok/on purpose
    && pip install -r requirements.txt  \
    && yes y | python3 -m pip uninstall pip \
    && apk del alpine-sdk build-deps linux-headers python3-dev \
    && rm -rf /tmp/* $HOME/.cache
WORKDIR /

ADD entrypoint.sh *.py /

ARG GITVERSION
ARG GITBRANCH
ARG DRONEBUILD
ENV OSIE_VERSION=${GITVERSION} OSIE_BRANCH=${GITBRANCH} DRONE_BUILD=${DRONEBUILD}
