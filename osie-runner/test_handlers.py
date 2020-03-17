import copy
import crypt
import json
import os
import re
import stat
import subprocess
import textwrap
import urllib.parse as parse
from unittest.mock import MagicMock, call

import dpath
from faker import Factory
from faker.providers import internet
import pytest

import handlers

fake = Factory.create()
fake.add_provider(internet)
tinkerbell = parse.urlparse(fake.url())


def test_remove_statefile(tmpdir):
    name = tmpdir + fake.file_path(depth=0)
    with open(name, "w") as f:
        f.write("fake text")

    assert os.path.exists(name)
    handlers.remove_statefile(name)
    assert not os.path.exists(name)


def reset_helpers():
    old = handlers.write_statefile
    handlers.write_statefile = MagicMock(side_effect=old)
    old = handlers.remove_statefile
    handlers.remove_statefile = MagicMock(side_effect=old)


@pytest.fixture
def phone_home():
    return MagicMock()


@pytest.fixture
def log():
    log = MagicMock()
    log.info = MagicMock()
    return log


@pytest.fixture
def handler_keep_wipe(phone_home, log, tmpdir):
    reset_helpers()
    host_state_dir = os.path.dirname(fake.file_path(depth=5))
    h = handlers.Handler(phone_home, log, tinkerbell, host_state_dir, tmpdir)
    h.run_osie = MagicMock()
    return h


@pytest.fixture
def handler(handler_keep_wipe):
    handler_keep_wipe.wipe = MagicMock()
    return handler_keep_wipe


def test_wipe(handler_keep_wipe):
    handler = handler_keep_wipe
    hwid = fake.uuid4()
    c = call(hwid, hwid, tinkerbell, handler.host_state_dir, "wipe.sh")
    calls = [c, call().check_returncode()]

    handler.wipe({"id": hwid})

    handler.phone_home.assert_not_called()
    handler.run_osie.assert_has_calls(calls)
    handlers.write_statefile.assert_not_called()


cacher_preinstalling = {
    "bonding_mode": 4,
    "facility_code": "test" + str(fake.random_int()),
    "id": str(fake.uuid4()),
    "network_ports": [],
    "plan_slug": "t1.small.x86",
    "preinstalled_operating_system_version": {"os_slug": "foo", "storage": {}},
    "state": "preinstalling",
}


def test_preinstalling(handler):
    hwid = cacher_preinstalling["id"]
    c = (
        hwid,
        "preinstall",
        tinkerbell,
        handler.host_state_dir,
        "flavor-runner.sh",
        ("-M", "/statedir/metadata"),
    )

    handler.handle_preinstalling(cacher_preinstalling)

    handler.phone_home.assert_called_with({"instance_id": hwid})
    handler.run_osie.assert_called_with(*c)
    handler.wipe.assert_not_called()
    handlers.write_statefile.assert_called_once()
    assert os.path.isfile(handler.statedir + "metadata")
    assert handlers.write_statefile.call_args[0][0] == handler.statedir + "metadata"


cacher_provisioning = {
    "bonding_mode": 4,
    "facility_code": "test" + str(fake.random_int()),
    "id": str(fake.uuid4()),
    "network_ports": [],
    "plan_slug": "t1.small.x86",
    "preinstalled_operating_system_version": {
        "image_tag": "image_tag",
        "os_slug": "foo",
        "storage": {},
    },
    "instance": {
        "crypted_root_password": crypt.crypt(fake.password()),
        "id": str(fake.uuid4()),
        "hostname": fake.user_name(),
        "ip_addresses": [
            {
                "address": fake.ipv4_public(),
                "address_family": 4,
                "management": True,
                "public": True,
            },
            {
                "address": fake.ipv4_private(),
                "address_family": 4,
                "management": True,
                "public": False,
            },
            {
                "address": fake.ipv6(),
                "address_family": 6,
                "management": True,
                "public": True,
            },
        ],
        "operating_system_version": {"image_tag": "image_tag", "os_slug": "foo"},
        "storage": {},
        "network_ready": True,
    },
    "state": "provisioning",
}  # noqa: E122


def userdata_generator(
    cacher, host="github.com", org="packethost", repo="packet-images", tag=""
):
    if tag == "":
        tag = cacher["preinstalled_operating_system_version"]["image_tag"]

    userdata = f"""\
            image_repo=https://{host}/{org}/{repo}
            image_tag={tag}
            """
    return textwrap.dedent(userdata)


@pytest.mark.parametrize(
    "path,value",
    [
        pytest.param(None, None, id="normal"),
        pytest.param("instance/userdata", None, id="userdata is None"),
        pytest.param("instance/userdata", False, id="userdata is not-None-Falsy"),
        pytest.param(
            "instance/userdata",
            userdata_generator(None, tag="image_tag"),
            id="full repo info in userdata",
        ),
    ],
)
def test_provisioning(handler, path, value):
    d = copy.deepcopy(cacher_provisioning)
    hwid = d["id"]
    iid = d["instance"]["id"]
    c = (
        hwid,
        iid,
        tinkerbell,
        handler.host_state_dir,
        "flavor-runner.sh",
        ("-M", "/statedir/metadata"),
        {"PACKET_BOOTDEV_MAC": ""},
    )

    if path:
        dpath.new(d, path, value)

    num_calls_write_statefile = 1
    has_user_data = False
    if path == "instance/userdata" and value:
        has_user_data = True
        num_calls_write_statefile += 1

        args = c[-2] + ("-u", "/statedir/userdata")
        c = c[:-2] + (args,) + c[-1:]

    handler.handle_provisioning(d)

    handler.phone_home.assert_called_with(
        {"type": "provisioning.104.01", "body": "Device connected to DHCP system"}
    )
    handler.run_osie.assert_called_with(*c)
    handler.wipe.assert_not_called()
    assert handlers.write_statefile.call_count == num_calls_write_statefile
    assert (
        handlers.write_statefile.call_args_list[0][0][0]
        == handler.statedir + "metadata"
    )
    assert os.path.isfile(handler.statedir + "metadata")
    if has_user_data:
        assert os.path.isfile(handler.statedir + "userdata")
        assert (
            handlers.write_statefile.call_args_list[1][0][0]
            == handler.statedir + "userdata"
        )


def test_provisioning_no_instance(handler):
    c = copy.deepcopy(cacher_provisioning)
    c.pop("instance")

    handler.handle_provisioning(c)

    handler.phone_home.assert_not_called()
    handler.run_osie.assert_not_called()
    handler.wipe.assert_not_called()
    handlers.write_statefile.assert_not_called()


@pytest.mark.parametrize(
    "path,value",
    [
        pytest.param(
            "instance/operating_system_version/os_slug",
            fake.slug(),
            id="os slug mismatch",
        ),
        pytest.param(
            "instance/operating_system_version/image_tag",
            fake.sha1(),
            id="os image_tag mismatch",
        ),
        pytest.param("instance/storage", None, id="storage is None"),
        pytest.param("instance/storage/foo", True, id="storage mismatch"),
        pytest.param(
            "instance/userdata",
            userdata_generator(cacher_provisioning, org="not-packethost"),
            id="userdata github.com org mismatch",
        ),
        pytest.param(
            "instance/userdata",
            userdata_generator(cacher_provisioning, repo="not-packet-images"),
            id="userdata github.com repo mismatch",
        ),
        pytest.param(
            "instance/userdata",
            userdata_generator(cacher_provisioning, tag=fake.sha1()),
            id="userdata github.com tag mismatch",
        ),
        pytest.param(
            "instance/userdata",
            userdata_generator(
                cacher_provisioning, host="images.packet.net", org="not-packethost"
            ),
            id="userdata images.packet.net org mismatch",
        ),
        pytest.param(
            "instance/userdata",
            userdata_generator(
                cacher_provisioning, host="images.packet.net", repo="not-packet-images"
            ),
            id="userdata images.packet.net repo mismatch",
        ),
        pytest.param(
            "instance/userdata",
            userdata_generator(
                cacher_provisioning, host="images.packet.net", tag=fake.sha1()
            ),
            id="userdata images.packet.net tag mismatch",
        ),
    ],
)
def test_provisioning_mismatch_preinstalled(handler, path, value):
    d = copy.deepcopy(cacher_provisioning)
    dpath.new(d, path, value)
    c = (
        d["id"],
        d["instance"]["id"],
        tinkerbell,
        handler.host_state_dir,
        "flavor-runner.sh",
        ("-M", "/statedir/metadata"),
        {"PACKET_BOOTDEV_MAC": ""},
    )

    if path == "instance/userdata" and value:
        args = c[-2] + ("-u", "/statedir/userdata")
        c = c[:-2] + (args,) + c[-1:]

    handler.handle_provisioning(d)

    handler.phone_home.assert_not_called()
    handler.run_osie.assert_called_with(*c)
    handler.wipe.assert_called_with(d)

    metadata = handler.statedir + "metadata"
    cleanup = handler.statedir + "cleanup.sh"
    userdata = handler.statedir + "userdata"

    assert os.path.isfile(cleanup)
    assert stat.S_IMODE(os.stat(cleanup).st_mode) == 0o700
    assert open(cleanup).read() == "#!/usr/bin/env sh\nreboot\n"

    assert os.path.isfile(metadata)
    assert handlers.write_statefile.call_args_list[0][0][0] == metadata
    assert handlers.write_statefile.call_args_list[-1][0][0] == cleanup

    handlers.remove_statefile.assert_not_called()
    write_satefile_count = 2
    if path == "instance/userdata" and value:
        assert os.path.isfile(userdata)
        write_satefile_count += 1
        assert handlers.write_statefile.call_args_list[1][0][0] == userdata

    assert handlers.write_statefile.call_count == write_satefile_count


def make_run_osie_dry_run():
    slugs = (
        "centos",
        "debian",
        "freebsd",
        "opensuse",
        "rhel",
        "scientific",
        "suse",
        "ubuntu",
        "virtuozzo",
        "windows",
    )
    regex = re.compile("^(" + "|".join(slugs) + ")")

    def run_osie_dry_run(*args):
        meta = json.loads(handlers.write_statefile.call_args[0][1])
        returncode = 1
        if regex.findall(meta["operating_system"]["slug"]):
            returncode = 0

        return subprocess.CompletedProcess(None, returncode)

    return run_osie_dry_run


@pytest.fixture
def mocked_run_osie(handler):
    handler.run_osie.side_effect = make_run_osie_dry_run()
    return handler


@pytest.mark.parametrize(
    "slug",
    [
        "centos_7",
        "debian_9",
        "freebsd_11_1",
        "opensuse_42_3",
        "rhel_7",
        "scientific_6",
        "suse_sles12",
        "ubuntu_16_04",
        "virtuozzo_7",
        "windows_2012_standard",
    ],
)
def test_different_os_positive(mocked_run_osie, slug):
    handler = mocked_run_osie

    d = copy.deepcopy(cacher_provisioning)
    dpath.new(d, "instance/operating_system_version/os_slug", slug)
    c = (
        d["id"],
        d["instance"]["id"],
        tinkerbell,
        handler.host_state_dir,
        "flavor-runner.sh",
        ("-M", "/statedir/metadata"),
        {"PACKET_BOOTDEV_MAC": ""},
    )

    stamp = handler.statedir + "disks-partioned-image-extracted"
    metadata = handler.statedir + "metadata"
    cleanup = handler.statedir + "cleanup.sh"

    open(stamp, "w").close()
    handler.handle_provisioning(d)

    handlers.remove_statefile.assert_called()
    handlers.remove_statefile.call_args[0][0] == stamp
    assert not os.path.exists(stamp)
    assert not os.path.exists(cleanup)
    assert handlers.write_statefile.call_count == 2
    assert handlers.write_statefile.call_args_list[0][0][0] == metadata
    assert handlers.write_statefile.call_args_list[1][0][0] == metadata
    assert os.path.exists(metadata)
    assert handler.run_osie.call_args_list == [call(*c), call(*c)]


def test_existence_of_loop_sh(mocked_run_osie):
    handler = mocked_run_osie

    cleanup = handler.statedir + "cleanup.sh"
    loop = handler.statedir + "loop.sh"
    metadata = handler.statedir + "metadata"
    stamp = handler.statedir + "disks-partioned-image-extracted"

    open(loop, "w").close()
    os.chmod(loop, 0o700)
    d = copy.deepcopy(cacher_provisioning)
    dpath.new(d, "instance/operating_system_version/os_slug", "freebsd_11_1")
    c = (
        d["id"],
        d["instance"]["id"],
        tinkerbell,
        handler.host_state_dir,
        "flavor-runner.sh",
        ("-M", "/statedir/metadata"),
        {"PACKET_BOOTDEV_MAC": ""},
    )

    assert handler.handle_provisioning(d)

    assert os.path.exists(loop)
    assert not os.path.exists(stamp)
    assert not os.path.exists(cleanup)

    assert handlers.write_statefile.call_count == 2
    assert handlers.write_statefile.call_args_list[0][0][0] == metadata
    assert handlers.write_statefile.call_args_list[1][0][0] == metadata
    assert os.path.exists(metadata)
    handler.run_osie.assert_called_with(*c)
