import utils
import re

from component.component import Component


class Disk(Component):
    @classmethod
    def list(cls, _):
        disks = []
        for disk in utils.lsblk():
            if not disk["name"].startswith("/dev/sd") and not disk["name"].startswith(
                "/dev/nvme"
            ):
                continue
            disks.append(cls(disk))
        return disks

    def __init__(self, lsblk):
        Component.__init__(self, lsblk, None)
        self.lsblk = lsblk
        self.data = {"size": self.__size(), "devname": self.lsblk["name"]}

        if not self.__is_nvme():
            self.data["smart"] = utils.get_smart_attributes(self.lsblk["name"])

        match = re.search(r"^(\S+)_(\S+_\S+)", self.__getter("model"))
        if match:
            self.vendor = match.group(1)
            self.model = match.group(2)
            self.name = match.group(1) + " " + match.group(2)
        else:
            self.model = self.__getter("model")
            self.name = self.model
            if self.lsblk["vendor"] is None:
                self.vendor = self.model.split(" ")[0]
            else:
                self.vendor = self.lsblk["vendor"].strip()

        self.serial = self.__getter("serial")
        self.firmware_version = self.__getter("firmware_version")

        if self.__is_megaraid():
            self.vendor = utils.get_smart_diskprop(self.lsblk["name"], "vendor")

        if self.vendor.strip() == "ATA":
            self.vendor = utils.normalize_vendor(self.model)
        else:
            self.vendor = utils.normalize_vendor(self.vendor)

    def __is_nvme(self):
        return self.lsblk["name"].startswith("/dev/nvme")

    def __is_megaraid(self):
        return self.lsblk["vendor"] in ("AVAGO", "PERC", "DELL", "LSI")

    def __getter(self, prop):
        if self.__is_nvme():
            if prop in self.lsblk:
                return self.lsblk[prop]
            else:
                return ""
        elif self.__is_megaraid():
            return utils.get_smart_diskprop(self.lsblk["name"], prop)
        else:
            return utils.get_hdparm_diskprop(self.lsblk["name"], prop)

    def __size(self):
        if self.__is_megaraid():
            return utils.get_smart_diskprop(self.lsblk["name"], "size")
        else:
            return self.lsblk["size"]
