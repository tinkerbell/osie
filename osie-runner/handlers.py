from datetime import datetime
import itertools
import json
import os
import re
import subprocess
import urllib.parse as parse


class Handler:
    def __init__(
        self, phone_home, log, tinkerbell, host_state_dir, statedir="/statedir/"
    ):
        self.phone_home = phone_home
        self.log = log
        self.tinkerbell = tinkerbell
        self.host_state_dir = host_state_dir
        self.statedir = os.path.normpath(statedir) + "/"

    @staticmethod
    def run_osie(
        hardware_id, instance_id, tinkerbell, statedir, command, args=(), env={}
    ):
        cmd = ("docker", "run", "--rm", "--privileged", "-ti", "-h", hardware_id)

        envs = (f"container_uuid={instance_id}", f"RLOGHOST={tinkerbell.hostname}")
        envs += tuple(itertools.starmap("=".join, zip(env.items())))
        # prepends a '-e' before each env
        cmd += tuple(itertools.chain(*zip(("-e",) * len(envs), envs)))

        volumes = (
            "/dev:/dev",
            "/dev/console:/dev/console",
            "/lib/firmware:/lib/firmware:ro",
            f"{statedir}:/statedir",
        )
        # prepends a '-v' before each volume
        cmd += tuple(itertools.chain(*zip(("-v",) * len(volumes), volumes)))
        cmd += ("--net", "host", "osie:x86_64", f"/home/packet/{command}")
        cmd += args

        return subprocess.run(cmd)

    def wipe(self, j):
        log = self.log
        statedir = self.host_state_dir
        tinkerbell = self.tinkerbell

        hardware_id = j["id"]
        log.info("wiping disks")
        ret = self.run_osie(hardware_id, hardware_id, tinkerbell, statedir, "wipe.sh")
        ret.check_returncode()

    def handle_preinstalling(self, j):
        log = self.log
        phone_home = self.phone_home
        statedir = self.host_state_dir
        tinkerbell = self.tinkerbell

        hardware_id = j["id"]

        args = ("-M", "/statedir/metadata")
        metadata = cacher_to_metadata(j, tinkerbell)
        write_statefile(self.statedir + "metadata", json.dumps(metadata))

        instance_id = metadata["id"]
        log = log.bind(hardware_id=hardware_id, instance_id=instance_id)
        start = datetime.now()

        log.info("running docker")
        self.run_osie(
            hardware_id, instance_id, tinkerbell, statedir, "flavor-runner.sh", args
        )
        log.info("finished", elapsed=str(datetime.now() - start))

        if j["state"] == "preinstalling":
            phone_home({"instance_id": hardware_id})

    def handle_provisioning(self, j):
        log = self.log
        statedir = self.host_state_dir
        tinkerbell = self.tinkerbell

        hardware_id = j["id"]
        instance = j.get("instance")
        if not instance:
            return

        mismatch = False

        pre = j["preinstalled_operating_system_version"]
        pretag = get_slug_tag(pre)
        instag = get_slug_tag(instance["operating_system_version"])
        if pretag != instag:
            log.info(
                "preinstalled does not match instance selection",
                preinstalled=pretag,
                instance=instag,
            )
            mismatch = True

        precpr = pre["storage"]
        inscpr = instance["storage"]
        if precpr != inscpr:
            log.info(
                "preinstalled cpr does not match instance cpr",
                preinstalled=precpr,
                instance=inscpr,
            )
            mismatch = True

        userdata = instance.get("userdata")
        if not userdata:
            userdata = ""
        custom_repo_tag = get_custom_image_from_userdata(userdata)
        pre_repo_tag = "https://github.com/packethost/packet-images#" + pre.get(
            "image_tag", ""
        )
        if custom_repo_tag and custom_repo_tag != pre_repo_tag:
            log.info(
                "using custom image",
                custom_repo_tag=custom_repo_tag,
                preinstalled_repo_tag=pre_repo_tag,
            )
            mismatch = True

        metadata = cacher_to_metadata(j, tinkerbell)

        network_ready = instance.get("network_ready")
        if not network_ready:
            log.info("network is not ready yet", network_ready=network_ready)
            return

        if mismatch:
            log.info("temporarily overriding state to osie.internal.check-env")
            old_state = metadata["state"]
            metadata["state"] = "osie.internal.check-env"

        env = {"PACKET_BOOTDEV_MAC": os.getenv("PACKET_BOOTDEV_MAC", "")}
        args = ("-M", "/statedir/metadata")
        log.info("writing metadata")
        write_statefile(self.statedir + "metadata", json.dumps(metadata))

        if userdata:
            log.info("writing userdata")
            write_statefile(self.statedir + "userdata", userdata)
            args += ("-u", "/statedir/userdata")

        instance_id = metadata["id"]
        log = log.bind(hardware_id=hardware_id, instance_id=instance_id)
        start = datetime.now()

        if mismatch:
            self.wipe(j)
            ret = self.run_osie(
                hardware_id,
                instance_id,
                tinkerbell,
                statedir,
                "flavor-runner.sh",
                args,
                env,
            )

            if ret.returncode != 0:
                log.info("setting up cleanup.sh with reboot")
                write_statefile(
                    self.statedir + "cleanup.sh",
                    "#!/usr/bin/env sh\n" + "reboot\n",
                    0o700,
                )
                return True

            log.info("reverting metadata to correct state")
            metadata["state"] = old_state
            log.info("writing metadata")
            write_statefile(self.statedir + "metadata", json.dumps(metadata))
            if os.path.exists(self.statedir + "disks-partioned-image-extracted"):
                log.info("deleting disks-partitioned-image-extracted file")
                remove_statefile(self.statedir + "disks-partioned-image-extracted")

            if os.access(self.statedir + "loop.sh", os.X_OK):
                log.info("exiting because osie needs something from the host")
                return True

            log.info("running install from scratch")
        else:
            log.info("ready to finish provision")

        log.info("sending provisioning.104.01 event")
        self.phone_home(
            {"type": "provisioning.104.01", "body": "Device connected to DHCP system"}
        )
        log.info("running docker")
        ret = self.run_osie(
            hardware_id,
            instance_id,
            tinkerbell,
            statedir,
            "flavor-runner.sh",
            args,
            env,
        )
        log.info("finished", elapsed=str(datetime.now() - start))
        ret.check_returncode()

        if os.access(self.statedir + "cleanup.sh", os.X_OK):
            log.info("exiting because osie is done")
            return True

    def handler(self, state):
        try:
            return getattr(self, "handle_" + state)
        except Exception:
            pass

    def handle(self, state, j):
        return getattr(self, "handle_" + state)(j)


def cacher_to_metadata(j, tinkerbell):
    instance = j.get("instance", None)
    if not instance:
        os = j["preinstalled_operating_system_version"]
        storage = os.pop("storage")
        instance = {
            "crypted_root_password": "preinstall",
            "hostname": "preinstall",
            "id": "preinstall",
            "ip_addresses": [],
            "operating_system_version": os,
            "storage": storage,
        }

    os = instance["operating_system_version"]
    os["slug"] = os["os_slug"]
    return {
        "class": j["plan_slug"],
        "facility": j["facility_code"],
        "hostname": instance["hostname"],
        "id": instance["id"],
        "network": {
            "addresses": instance["ip_addresses"],
            "bonding": {"mode": j["bonding_mode"]},
            "interfaces": [
                {"bond": p["data"]["bond"], "mac": p["data"]["mac"], "name": p["name"]}
                for p in j["network_ports"]
                if p["type"] == "data"
            ],
        },
        "operating_system": os,
        "password_hash": instance.get("crypted_root_password"),
        "phone_home_url": parse.urljoin(tinkerbell.geturl(), "phone-home"),
        "plan": j["plan_slug"],
        "state": j["state"],
        "storage": instance.get("storage", ""),
    }  # noqa: E122


def write_statefile(name, content, mode=0o644):
    with open(name, "w") as f:
        f.write(content)
        f.flush()
        os.fchmod(f.fileno(), mode)


def remove_statefile(name):
    os.remove(name)


def get_slug_tag(os):
    tag = os.get("image_tag")
    if not tag:
        tag = ""
    try:
        os_slug = os["os_slug"]
    except KeyError as ke:
        raise AttributeError(
            "required key missing from cacher data, key=%s" % (ke.args[0])
        )
    return os_slug + ":" + tag


def get_custom_image_from_userdata(userdata):
    # needs to stay in sync with osie's code
    repo = re.search(r".*\bimage_repo=(\S+).*", userdata)
    tag = re.search(r".*\bimage_tag=(\S+).*", userdata)
    if repo and tag:
        return repo.group(1) + "#" + tag.group(1)
