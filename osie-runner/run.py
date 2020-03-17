#!/usr/bin/env python3

import itertools
import json
import logging
import os
import sys
import time
import urllib.parse as parse

import grpc
import requests

import hegel_pb2 as hegel
import hegel_pb2_grpc
import log
import handlers

import util

logging.basicConfig(format="%(message)s", stream=sys.stdout, level=logging.INFO)
log = log.logger("runner")


def phone_homer(url):
    def func(json):
        log.info("phoning home", json=json)
        resp = requests.put(url, json=json)
        if not resp.ok:
            log.error("failed to phone-home", code=resp.status_code, reason=resp.reason)

    return func


def failer():
    def func(reason):
        return phone_home({"type": "failure", "reason": reason})

    return func


def connect_hegel(stub):
    iterations = 0
    for backoff in itertools.chain((0, 1, 2, 5, 10), itertools.repeat(10)):
        try:
            if backoff > 0:
                log.info("failed to connect, sleeping for %s seconds" % backoff)
                time.sleep(backoff)
                log.info("attempting to reconnect to hegel", attempt=iterations)

            resp = stub.Get(hegel.GetRequest())
            watch = stub.Subscribe(hegel.SubscribeRequest())
            iterations += 1
            return watch, resp
        except grpc.RpcError:
            pass


with open("/proc/cmdline", "r") as cmdline:
    cmdline_content = cmdline.read()
    tinkerbell = parse.urlparse(util.value_from_kopt(cmdline_content, "tinkerbell"))
    facility = util.value_from_kopt(cmdline_content, "facility")

phone_home = phone_homer(parse.urljoin(tinkerbell.geturl(), "phone-home"))
fail = failer()

statedir = os.getenv("STATEDIR_HOST")
if not statedir:
    fail("STATEDIR_HOST env var is missing, unable to proceed")

authority = "hegel.packet.net:50060"
if facility == "lab1":
    authority = "hegel-lab1.packet.net:50060"

creds = grpc.ssl_channel_credentials()
channel = grpc.secure_channel(authority, creds)
stub = hegel_pb2_grpc.HegelStub(channel)
watch, resp = connect_hegel(stub)

# TODO decide to keep or remove? means we'd ignore a failed deprov
log.info("wiping disk partitions")
handlers = handlers.Handler(phone_home, log, tinkerbell, statedir)
handlers.wipe(json.loads(resp.JSON))

log.info("running subscribe loop")
while True:
    j = json.loads(resp.JSON)
    # note: do not try to ignore pushes with out state changes, network
    # sometimes comes in after state:provisioning for example
    state = j["state"]
    i = j.get("instance", {"state": ""})
    log.info("context updated", state=state, instance_state=i.get("state", ""))

    handler = handlers.handler(state)
    if handler:
        try:
            exit = handler(j)
            if exit:
                break
        except Exception as e:
            log.exception("handler failed")
            fail(str(e))

    else:
        log.info("no handler for state", state=state)

    log.info("about to monitor")
    try:
        resp = watch.next()
    except grpc.RpcError as e:
        log.exception("grpc error")
        log.info("hegel went away, attempting to reconnect")
        while True:
            try:
                watch, resp = connect_hegel(stub)
                break
            except Exception as e:
                log.error("could not connect to hegel, sleeping a bit")
                time.sleep(1)
                log.error("woke up, trying again")

sys.exit(0)
