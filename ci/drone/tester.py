#!/usr/bin/env python3

from __future__ import print_function

import datetime
import functools
import os
import socket
import sys
import time

import packet

project = os.environ["PACKET_PROJECT_ID"]
token = os.environ["PACKET_API_TOKEN"]
hostname = os.environ["DEVICE_HOSTNAME"]
ipxe_script_url = os.environ["DEVICE_IPXE_SCRIPT_URL"]
plan = os.environ["DEVICE_PLAN"]
facility = os.environ["DEVICE_FACILITY"]

timeout = 600

if sys.version_info[0] == 2:
    oldprint = print

    def myprint(*args, **kwargs):
        flush = kwargs.pop("flush", False)
        f = kwargs.get("file", sys.stdout)

        oldprint(*args, **kwargs)

        if flush:
            f.flush()

    print = functools.update_wrapper(myprint, print)

print = functools.partial(print, hostname + ":", flush=True)


class Device:
    def __init__(self, manager):
        self.m = manager
        self.dev = None
        self.id = None
        self.ip = None

    def __until(self, func):
        """
        Runs `func` in a loop until timeout or func returns Falsy. Will handle
        504 errors in a way that makes sense. Stop is indicated as Falsy so that
        funcs do not have to explicitly return anything, Python's implicit None
        will break the loop.
        """
        end = time.time() + timeout
        while end > time.time():
            try:
                if not func():
                    return
            except packet.baseapi.Error as e:
                if "504" in str(e):
                    print("504")
                    time.sleep(30)
                    continue
                print(e)
                sys.exit(1)

            time.sleep(10)

        print("timed out")
        sys.exit(1)

    def create(self, project, hostname, plan, facility, ipxe_script_url):
        def __create():
            tt = datetime.datetime.utcnow() + datetime.timedelta(hours=2)
            d = self.m.create_device(
                project,
                hostname,
                plan,
                facility,
                "custom_ipxe",
                ipxe_script_url=ipxe_script_url,
                spot_instance=True,
                spot_price_max=20,
                termination_time=tt.isoformat(),
            )

            self.dev = d
            self.id = d.id

        self.__until(__create)

    def refresh(self):
        def __refresh():
            d = self.m.get_device(self.id)
            self.dev = d
            if d.ip_addresses and not self.ip:
                ips = [
                    ip
                    for ip in d.ip_addresses
                    if ip["address_family"] == 4 and ip["public"]
                ]
                if ips:
                    self.ip = ips[0]["address"]

        self.__until(__refresh)

    def state(self):
        self.refresh()
        return self.dev.state

    def wait_for_ssh(self):
        def __wait_for_ssh():
            if self.state() != "active":
                print(self, "state is not active")
                return

            s = socket.socket()
            s.settimeout(10)
            try:
                s.connect((self.ip, 22))
                msg = s.recv(100).decode()
            except socket.error:
                return True

            if "ssh" in msg.lower():
                print(self, msg.strip())
                return

            print(self, "not ssh greeting")

        self.__until(__wait_for_ssh)

    def delete(self):
        def __delete():
            self.dev.delete()

        self.__until(__delete)

    def __repr__(self):
        state = None
        if self.dev:
            state = self.dev.state
        return "{} {} {}".format(self.id, state, self.ip)


def main():
    print("instantiating manager")
    m = packet.Manager(token)
    print("instantiating device")
    d = Device(m)
    print("creating device")
    d.create(project, hostname, plan, facility, ipxe_script_url)
    start = time.time()
    print(d)

    state = None
    while True:
        state, oldstate = d.state(), state
        if state != oldstate:
            print(d)
        if state == "active":
            break
        time.sleep(30)

    d.wait_for_ssh()
    print(d, "time-to-active", time.time() - start)
    print(d, "deleting")
    d.delete()
    print(d, "test-time", time.time() - start)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(hostname + ":", e)
