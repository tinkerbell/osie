from __future__ import print_function

import copy
import re


def _perform_action(device, disk=None, pretend=False):
    actions = ["-o"]
    infos = ["-p"]
    if disk:
        guid = disk.get("guid", None)
        if guid is not None:
            actions.append("-U%s" % guid)

        autoinc = 1
        for num, p in sorted(disk["partitions"].items()):
            num = p.get("number", 0)
            start = p.get("start", 0)
            end = p.get("end", 0)
            cmdlet = ["-n{num}:{start}:{end}"]

            guid = p.get("guid", None)
            if guid:
                cmdlet.append("-u{num}:{guid}")

            type = p.get("type", None)
            if type:
                cmdlet.append("-t{num}:{type}")

            name = p.get("name", None)
            if name:
                cmdlet.append("-c{num}:{name}")

            cmdlet = " ".join(cmdlet)
            cmdlet = cmdlet.format(
                num=num, start=start, end=end, guid=guid, type=type, name=device
            )
            actions.append(cmdlet)

            if num == 0:
                num = autoinc
                autoinc += 1

            infos.append("-i%d" % num)

        actions = " ".join(actions)
        infos = " ".join(infos)

    cmd = "sgdisk -P {actions} {infos} {name}".format(
        actions=actions, infos=infos, name=device
    )
    out = __salt__["cmd.run"](cmd)
    info = _parse_disk_info(out)

    if info is None:
        return info

    if disk is None and len(info["partitions"]) > 0:
        info = _get_disk_info(name, info["partitions"].keys())

    return info


def _get_disk_info(disk, partitions=None):
    parts = ""
    if partitions:
        parts = " ".join(["-i%d" % p for p in partitions])

    cmd = "sgdisk -P -p %s %s" % (parts, disk)
    out = __salt__["cmd.run"](cmd)
    info = _parse_disk_info(out)

    if info is None:
        return info

    if partitions is None and len(info["partitions"]) > 0:
        info = _get_disk_info(disk, info["partitions"].keys())

    return info


disk_guid_re = re.compile("^Disk identifier \(GUID\): (\S*)", re.M)
partition_basic_re = "^\s+(?P<number>\d+)\s+(?P<start>\d+)\s+(?P<end>\d+)"
partition_basic_re = re.compile(partition_basic_re, re.M)
partition_flags_re = re.compile("Attribute flags: (\d+)")
partition_type_re = re.compile("Partition GUID code: (\S*)")
partition_guid_re = re.compile("Partition unique GUID: (\S*)")
partition_name_re = re.compile("Partition name: '(\w*)'", re.U)


def _parse_disk_info(out):
    disk_guid = disk_guid_re.findall(out)
    if not disk_guid:
        return None

    assert len(disk_guid) == 1
    disk = {"guid": disk_guid[0], "partitions": {}}

    basics = partition_basic_re.findall(out)
    if not basics:
        return disk

    regexes = (
        partition_type_re,
        partition_guid_re,
        partition_flags_re,
        partition_name_re,
    )
    types, guids, flags, names = [regex.findall(out) for regex in regexes]

    assert len(types) == len(guids) == len(flags) == len(names), (
        "mismatched lengths: types=%d guids=%d flags=%d names=%d"
        % (len(types), len(guids), len(flags), len(names))
    )

    if len(basics) != len(types):
        assert len(basics) > len(
            types
        ), "basic info must be >= detailed info: %d, %d" % (len(basics), len(types))

        n = len(basics) - len(types)
        for info in (types, guids, flags, names):
            info += [""] * n

    partitions = {}
    for info in zip(basics, types, guids, flags, names):
        part = {
            "number": int(info[0][0]),
            "start": info[0][1],
            "end": info[0][2],
            "type": info[1],
            "guid": info[2],
            "flags": info[3],
            "name": info[4],
        }
        partitions[part["number"]] = part

    disk["partitions"] = partitions
    return disk


def absent(name):
    ret = {"name": name, "changes": {}, "result": False, "comment": "", "pchanges": {}}

    print("info:", __salt__["partition.list"](name)["info"])
    _label = __salt__["partition.list"](name)["info"]["partition table"]

    if _label == "unknown":
        ret["result"] = True
    else:
        ret["changes"].update({"label": {"old": _label, "new": "unpartioned"}})
        if __opts__["test"]:
            ret["result"] = None

    return ret


def labeled(name):
    ret = {"name": name, "changes": {}, "result": False, "comment": "", "pchanges": {}}

    label = __salt__["partition.list"](name)["info"]["partition table"]

    if label == "gpt":
        ret["result"] = True
    else:
        ret["changes"].update({"label": {"old": label, "new": "gpt"}})
        if __opts__["test"]:
            ret["result"] = None

    return ret


def _render_disk(guid, partitions):
    disk = {"guid": None, "partitions": {}}

    autoinc = 1
    for p in partitions:
        num = int(p.get("number", 0))
        start = p.get("start", 0)
        end = p.get("end", 0)
        guid = p.get("guid", "")
        type = p.get("type", "")
        name = p.get("name", "")

        if num == 0:
            num = autoinc
            autoinc += 1

        disk["partitions"][num] = {
            "number": num,
            "start": start,
            "end": end,
            "guid": guid,
            "type": type,
            "name": name,
        }

    return disk


def _merge_disks(new, old):
    if old is None:
        return new

    if new["guid"] is None:
        new["guid"] = old["guid"]

    for num, part in new["partitions"].items():
        oldpart = old["partitions"].get(num, None)
        if oldpart is None:
            continue

        # lets delete all falsy values so that when we do
        # oldpart.update(part) the falsy values don't override what oldpart had
        for key, value in part.items():
            if not value:
                part.pop(key)

        newpart = copy.deepcopy(oldpart)
        newpart.update(part)
        new["partitions"][num] = newpart

    return new


def partioned(name, guid=None, partitions=None):
    ret = {"name": name, "changes": {}, "result": True, "comment": "", "pchanges": {}}

    current = _get_disk_info(name)

    arg = _render_disk(guid, partitions)
    arg = _merge_disks(arg, current)

    new = _perform_action(name, arg)

    if new != current:
        ret["result"] = None
        ret["changes"] = {"old": current, "new": new}

    return ret
