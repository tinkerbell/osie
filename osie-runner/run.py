#!/usr/bin/env python3

import copy
import itertools
import json
import logging
import os
import sys
import time
import urllib.parse as parse

import grpc
import requests
import srvlookup

import hegel_pb2 as hegel
import hegel_pb2_grpc
import log
import handlers

import util

from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry import context
from opentelemetry.instrumentation.requests import RequestsInstrumentor
from opentelemetry.instrumentation.grpc import GrpcInstrumentorClient
from opentelemetry import propagate

logging.basicConfig(format="%(message)s", stream=sys.stdout, level=logging.INFO)
log = log.logger("runner")

trace.set_tracer_provider(TracerProvider())
tracer = trace.get_tracer_provider().get_tracer(__name__)
# opentelemetry-python does not support OTEL_EXPORTER_OTLP_INSECURE so do it here
# https://opentelemetry-python.readthedocs.io/en/latest/exporter/otlp/otlp.html
otel_insecure = os.getenv("OTEL_EXPORTER_OTLP_INSECURE", "false").lower() in (
    "1",
    "true",
)
trace.get_tracer_provider().add_span_processor(
    BatchSpanProcessor(OTLPSpanExporter(insecure=otel_insecure))
)
RequestsInstrumentor().instrument()
GrpcInstrumentorClient().instrument()


def load_otel_traceparent(kernel_tp):
    """
    Sets up OpenTelemetry after loading traceparent from either the kernel
    cmdline or the TRACEPARENT environment variable.
    """

    traceparent = None
    if kernel_tp is None:
        traceparent = os.getenv("TRACEPARENT")
        if traceparent is None or not traceparent.strip():
            return
    else:
        traceparent = kernel_tp

    if traceparent is not None:
        # got a tp from kernel or env, create a context with it as the current span
        ctx = propagate.extract({"traceparent": [traceparent]})
        context.attach(ctx)
    else:
        # no traceparent was available, start a span of our own and return it as tp
        # so downstream code can always assume there's a tp and not check it
        with tracer.start_as_current_span("run.py", kind=trace.SpanKind.SERVER):
            carrier = {}
            propagate.inject(carrier)
            traceparent = carrier["traceparent"]

    return traceparent


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


def get_hegel_authority(facility):
    try:
        srv = srvlookup.lookup("grpc", domain=f"hegel.{facility}.packet.net")[0]
        return f"{srv.hostname}:{srv.port}"
    except:
        authority = "hegel.packet.net:50060"
        if facility == "lab1":
            authority = "hegel-lab1.packet.net:50060"

        return authority


def connect_hegel(facility):
    creds = grpc.ssl_channel_credentials()

    iterations = 0
    for backoff in itertools.chain((0, 1, 2, 5, 10), itertools.repeat(10)):
        iterations += 1
        authority = get_hegel_authority(facility)
        log.info("connecting to", authority=authority)
        # Timeouts: https://cs.mcgill.ca/~mxia3/2019/02/23/Using-gRPC-in-Production/
        channel = grpc.secure_channel(
            authority,
            creds,
            options=[
                ("grpc.keepalive_time_ms", 10000),
                ("grpc.keepalive_timeout_ms", 5000),
                ("grpc.keepalive_permit_without_calls", 1),
                ("grpc.http2.max_pings_without_data", 0),
                ("grpc.http2.min_time_between_pings_ms", 10000),
                ("grpc.http2.min_ping_interval_without_data_ms", 5000),
            ],
        )
        stub = hegel_pb2_grpc.HegelStub(channel)

        try:
            if backoff > 0:
                log.info("failed to connect, sleeping for %s seconds" % backoff)
                time.sleep(backoff)
                log.info("attempting to reconnect to hegel", attempt=iterations)

            resp = stub.Get(hegel.GetRequest())
            watch = stub.Subscribe(hegel.SubscribeRequest())
            return watch, resp
        except grpc.RpcError:
            pass


def sanitize_cacher_data(j):
    j = copy.deepcopy(j)
    try:
        j["instance"]["userdata"] = "~~ OMITTED ~~"
    except Exception as e:
        pass
    return j


with open("/proc/cmdline", "r") as cmdline:
    cmdline_content = cmdline.read()
    tinkerbell = parse.urlparse(util.value_from_kopt(cmdline_content, "tinkerbell"))
    facility = util.value_from_kopt(cmdline_content, "facility")
    kernel_tp = util.value_from_kopt(cmdline_content, "traceparent")  # opentelemetry

traceparent = load_otel_traceparent(kernel_tp)

phone_home = phone_homer(parse.urljoin(tinkerbell.geturl(), "phone-home"))
fail = failer()

statedir = os.getenv("STATEDIR_HOST")
if not statedir:
    fail("STATEDIR_HOST env var is missing, unable to proceed")

watch, resp = connect_hegel(facility)

# TODO decide to keep or remove? means we'd ignore a failed deprov
log.info("wiping disk partitions")
handlers = handlers.Handler(phone_home, log, tinkerbell, statedir, traceparent)
handlers.wipe(json.loads(resp.JSON))

log.info("running subscribe loop")
while True:
    j = json.loads(resp.JSON)
    # note: do not try to ignore pushes with out state changes, network
    # sometimes comes in after state:provisioning for example
    state = j["state"]
    i = j.get("instance", {"state": ""})
    log.info("context updated", state=state, instance_state=i.get("state", ""))
    print(json.dumps(sanitize_cacher_data(j), indent=2))

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
        log.info("hegel went away, attempting to reconnect")
        while True:
            try:
                watch, resp = connect_hegel(facility)
                break
            except Exception as e:
                log.error("could not connect to hegel, sleeping a bit")
                time.sleep(1)
                log.error("woke up, trying again")

sys.exit(0)
