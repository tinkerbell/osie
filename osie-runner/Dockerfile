FROM alpine:3.12

ENTRYPOINT ["/entrypoint.sh"]
CMD ["python3", "run.py"]
VOLUME /statedir

RUN apk add --update --upgrade --no-cache bash curl docker jq libstdc++ python3
COPY requirements.txt .
RUN apk add --update --upgrade --no-cache --virtual build-deps alpine-sdk python3-dev py3-pip && \
	pip3 install -r requirements.txt && \
	apk del build-deps && \
	rm -f requirements.txt
ADD entrypoint.sh *.py /
