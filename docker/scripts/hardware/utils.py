import hashlib
import inspect
import json
import os
import re
import subprocess
import tempfile
import urllib.error
import urllib.request

from lxml import etree


def http_download_file(_uri, _fh, _hash):
    _response = http_request(_uri)

    if _response:
        _chunk = 16 * 1024
        _sha512 = hashlib.sha512()

        with os.fdopen(_fh, "wb") as f:
            for c in iter(lambda: _response.read(_chunk), ""):
                _sha512.update(_chunk)
                f.write(c)

        if _sha512.hexdigest() == _hash:
            return True
        else:
            log(error="Hash failed verification!")

    return False


def http_request(_uri, _body="", _method="GET", _content_type="application/json"):
    req = urllib.request.Request(_uri)
    req.add_header("Content-Type", _content_type)

    try:
        response = urllib.request.urlopen(req, _body.encode("utf8"))
    except urllib.error.HTTPError as e:
        log(
            method=_method, uri=_uri, code=str(e.code), reason=str(e.reason), body=_body
        )
        return False
    except urllib.error.URLError as e:
        log(method=_method, uri=_uri, reason=str(e.reason))
        return False

    log(method=_method, uri=_uri, status=response.status)

    return response


def xml_ev(t, e, v, is_attrib=False):
    value = []

    if is_attrib:
        value = t.xpath(t.getpath(e) + "/" + v)
    else:
        value = t.xpath(t.getpath(e) + "/" + v + "/text()")

    if len(value) == 1:
        return value[0]
    else:
        return ""


def cmd_output(*cmd):
    log(cmd=" ".join(cmd))

    process = subprocess.Popen(cmd, stderr=subprocess.PIPE, stdout=subprocess.PIPE)
    out, err = process.communicate()
    retcode = process.poll()

    if retcode:
        log(cmd=cmd[0], errorcode=retcode)
        return ""

    return out.decode()


def ethtool_mac(interface_name):
    out = cmd_output("ethtool", "-P", interface_name)
    match = re.match(r"Permanent address: (.*)", out)
    return match.group(1)


def lsblk():
    lsblk_json = cmd_output(
        "lsblk", "-J", "-p", "-o", "NAME,SERIAL,MODEL,SIZE,REV,VENDOR"
    )
    return json.loads(lsblk_json)["blockdevices"]


def get_smart_devices():
    smart_data = cmd_output("smartctl", "--scan-open")
    smart_map = {}

    disks = []
    for file in os.listdir("/dev"):
        if re.compile("^sd[a-z]$").match(file):
            disks.append(os.path.join("/dev", file))

    counter = 0

    comment_regex = re.compile("^#")
    for line in smart_data.splitlines():
        if comment_regex.match(line):
            continue

        dev, _, disk_type = line.split(" ")[0:3]

        if "megaraid" not in disk_type:
            continue

        smart_map[disks[counter]] = disk_type
        counter += 1

    return smart_map


def get_smart_attributes(device):
    start_line = 0
    attributes = cmd_output("smartctl", "-A", device).splitlines()

    for idx, line in enumerate(attributes):
        col = line.split()
        if len(col) > 1 and col[1] == "ATTRIBUTE_NAME":
            start_line = idx + 1
            break

    smart_attributes = []

    if start_line == 0:
        return smart_attributes

    attribute_keys = (
        "id",
        "name",
        "flag",
        "value",
        "worst",
        "threshold",
        "type",
        "updated",
        "when_failed",
        "raw_value",
    )

    for attr in attributes[start_line:]:
        if len(attr) == 0:
            continue
        smart_attributes.append(dict(zip(attribute_keys, attr.split())))

    return smart_attributes


def get_smart_diskprop(device, prop):
    regex = {
        "model": re.compile(r"^Model Family:\s+(.*)$", re.MULTILINE),
        "serial": re.compile(r"^Serial Number:\s+(.*)$", re.MULTILINE),
        "firmware_version": re.compile(r"^Firmware Version:\s+(.*)$", re.MULTILINE),
        "vendor": re.compile(r"^Device Model:\s+(.*)$", re.MULTILINE),
        "size": re.compile(r"^User Capacity:\s+.*\[(.*)\]$", re.MULTILINE),
    }

    if prop not in regex:
        return ""

    smart_data = cmd_output("smartctl", "-d", get_smart_devices()[device], "-i", device)

    return __re_multiline_first(smart_data, regex[prop]).strip()


def get_hdparm_diskprop(device, prop):
    regex = {
        "model": re.compile(r"^\s+Model Number:\s+(.*)$", re.MULTILINE),
        "serial": re.compile(r"^\s+Serial Number:\s+(.*)$", re.MULTILINE),
        "firmware_version": re.compile(r"^\s+Firmware Revision:\s+(.*)$", re.MULTILINE),
    }

    if prop not in regex:
        return ""

    hdparm_data = cmd_output("hdparm", "-I", device)

    return __re_multiline_first(hdparm_data, regex[prop]).strip()


def __re_multiline_first(data, regex_c):
    m = regex_c.search(data)

    if m is not None:
        return m.group(1)

    return ""


def get_megaraid_prop(prop):
    regex = {
        "serial": re.compile(r"^Serial No\s*:\s*(\S*)\n", re.MULTILINE),
        "memory_size": re.compile(r"^Memory Size\s*:\s*(.*)$", re.MULTILINE),
        "product_name": re.compile(r"^Product Name\s*:\s*(.*)$", re.MULTILINE),
        "firmware_bios": re.compile(r"^BIOS Version\s*:\s*(.*)$", re.MULTILINE),
        "firmware_ctrlr": re.compile(r"^Ctrl-R Version\s*:\s*(.*)$", re.MULTILINE),
        "firmware_fw": re.compile(r"^FW Version\s*:\s*(.*)$", re.MULTILINE),
        "firmware_nvdata": re.compile(r"^NVDATA Version\s*:\s*(.*)$", re.MULTILINE),
        "firmware_boot": re.compile(r"^Boot Block Version\s*:\s*(.*)$", re.MULTILINE),
        "bbu": re.compile(r"^BBU\s*:\s*(.*)$", re.MULTILINE),
    }

    if prop not in regex:
        return "Unknown"

    megaraid_data = cmd_output("MegaCli64", "-AdpAllInfo", "-aALL")
    return __re_multiline_first(megaraid_data, regex[prop]).strip()


def lshw():
    return cmd_output("lshw", "-xml", "-quiet")


def lspci(pci_id):
    _lspci = {}

    for _line in cmd_output("lspci", "-vmmQ", "-s", pci_id).splitlines():
        _match = re.search(r"^(.+):\s+(.+)", _line)
        if _match:
            _lspci[_match.group(1).lower()] = _match.group(2)

    return _lspci


def get_mellanox_prop(pci_id, prop):
    regex = {
        "firmware_version": re.compile(r"^FW Version:\s*(.*)$", re.MULTILINE),
        "psid": re.compile(r"^PSID:\s*(.*)$", re.MULTILINE),
    }

    if prop not in regex:
        return "Unknown"

    mellanox_data = mstflint_query(pci_id)
    return __re_multiline_first(mellanox_data, regex[prop]).strip()


def mstflint(pci_id, *cmd):
    cmd = ("mstflint", "-d", pci_id) + cmd

    return cmd_output(*cmd)


def mstflint_query(pci_id):
    return mstflint(pci_id, "query", "full")


def mstflint_firmware_hash(pci_id):
    _tmpfile = next(tempfile._get_candidate_names())
    mstflint(pci_id, "ri", _tmpfile)

    _hash_sha512 = hashlib.sha512()
    with open(_tmpfile, "rb") as f:
        for chunk in iter(lambda: f.read(4096), b""):
            _hash_sha512.update(chunk)

    os.unlink(_tmpfile)
    return _hash_sha512.hexdigest()


def mlxup_firmware(pci_id, firmware, _hash):
    with tempfile.NamedTemporaryFile() as _file:
        _output = ""

        if http_download_file(firmware, _file, _hash):
            _output = cmd_output(
                "/opt/mellanox/mlxup",
                "-d",
                pci_id,
                "-i",
                _file.name,
                "--no-progress",
                "--yes",
            )

        return _output


def mlxup_online(pci_id):
    return cmd_output(
        "/opt/mellanox/mlxup", "-d", pci_id, "--online", "-u", "--no-progress", "--yes"
    )


def mlxup_query(pci_id):
    return cmd_output(
        "/opt/mellanox/mlxup", "-d", pci_id, "--query", "--query-format", "XML"
    )


def mlxup_upgradable(pci_id):
    tree = etree.ElementTree(etree.fromstring(mlxup_query(pci_id)))

    if tree.xpath("/Devices/Device/Status/text()")[0] == "Update required":
        return True

    return False


def mellanox_isdell(pci_id):
    _psid = get_mellanox_prop(pci_id, "psid")

    if _psid.startswith("DEL"):
        return True

    return False


def get_dmidecode_prop(handle, dmi_type, prop):
    dmi_data = dmidecode(dmi_type)

    r = re.compile(
        r"^Handle (\S+), DMI type 17, 40 bytes\nMemory Device((?:\n.+)+)", re.MULTILINE
    )
    for (dmi_handle, body) in re.findall(r, dmi_data):
        if handle != dmi_handle:
            continue

        if prop == "type":
            type_regex = re.compile(r"^\s*Type: (\S*)\n", re.MULTILINE)
            return __re_multiline_first(body, type_regex).strip()
        else:
            return "Unknown"


def dmidecode_string(dmi_string):
    return cmd_output("dmidecode", "-s", dmi_string).strip()


def dmidecode(dmi_type):
    return cmd_output("dmidecode", "-t", dmi_type)


def log(*args, **kwargs):
    m = ""

    if args:
        m = " ".join(args)

    if kwargs:
        if "klass" not in kwargs:
            caller_locals = inspect.stack()[1][0].f_locals
            if "self" in caller_locals:
                kwargs["klass"] = caller_locals["self"].__class__.__name__
            else:
                kwargs["klass"] = "utils"

        if "method" not in kwargs:
            kwargs["method"] = inspect.stack()[1][0].f_code.co_name

        if m:
            m += " "
        m += kvp(**kwargs)

    print(m)
    return m


def kvp(**kwargs):
    return ", ".join(('%s="%s"' % (k, v) for k, v in kwargs.items()))


def normalize_vendor(vendor_string):
    vendor_re = {
        "Intel": re.compile(r"^INTEL", re.IGNORECASE),
        "Micron Technology": [
            re.compile(r"^MICRON", re.IGNORECASE),
            re.compile(r"^002C00B3002C", re.IGNORECASE),
        ],
        "Synnex": re.compile(r"^SYNNEX", re.IGNORECASE),
        "Samsung": re.compile(r"^SAMSUNG", re.IGNORECASE),
        "Foxconn": re.compile(r"^FOXCONN", re.IGNORECASE),
        "Quanta": re.compile(r"^QUANTA", re.IGNORECASE),
        "Hynix/Hyundai": re.compile(r"^HYNIX", re.IGNORECASE),
        "Supermicro": re.compile(r"^SUPERMICRO", re.IGNORECASE),
        "LSI Logic": re.compile(r"^LSI", re.IGNORECASE),
        "Dell Inc.": re.compile(r"^DELL", re.IGNORECASE),
        "Mellanox Technologies": re.compile(r"^MELLANOX", re.IGNORECASE),
        "Toshiba": re.compile(r"^TOSHIBA", re.IGNORECASE),
        "Cavium, Inc.": re.compile(r"^CAVIUM", re.IGNORECASE),
    }

    for vendor_name, regex in vendor_re.items():
        if not isinstance(regex, list):
            regex = [regex]

        if any(map(lambda r: r.search(vendor_string), regex)):
            return vendor_name

    return vendor_string


def get_mc_info(prop):
    regex = {
        "vendor": re.compile(r"^Manufacturer Name\s+:\s+(.*)$", re.MULTILINE),
        "firmware_version": re.compile(r"^Firmware Revision\s+:\s+(.*)$", re.MULTILINE),
        "guid": re.compile(r"^System GUID\s+:\s+(.*)$", re.MULTILINE),
    }

    if prop not in regex:
        return ""

    mc_info = cmd_output("ipmitool", "mc", "guid") + cmd_output(
        "ipmitool", "mc", "info"
    )

    return __re_multiline_first(mc_info, regex[prop]).strip()
