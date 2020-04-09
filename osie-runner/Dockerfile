FROM alpine:3.11

ENTRYPOINT ["/entrypoint.sh"]
CMD ["python3", "run.py"]
VOLUME /statedir

RUN apk add --update --upgrade --no-cache bash curl docker jq libstdc++ python3
ADD requirements.txt .
RUN apk add --update --upgrade --no-cache --virtual build-deps alpine-sdk python3-dev && \
	pip3 install -r requirements.txt && \
	apk del build-deps && \
	rm -f requirements.txt
ADD entrypoint.sh *.py /
