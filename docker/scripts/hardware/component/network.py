import utils

from lxml import etree

from component.component import Component


class Network(Component):
    @classmethod
    def list(cls, lshw):
        xpath = etree.XPath("//node[@class='network'][@handle!=''][logicalname]")

        networks = []
        for network in xpath(lshw):
            if utils.xml_ev(lshw, network, "logicalname") == "bond0":
                continue
            networks.append(cls(lshw, network))

        return networks

    def __init__(self, lshw, element):
        Component.__init__(self, lshw, element)

        self.data = {
            "rate": utils.xml_ev(lshw, element, "size"),
            "devname": utils.xml_ev(lshw, element, "logicalname"),
            "driver": utils.xml_ev(
                lshw, element, "configuration/setting[@id='driver']/@value", True
            ),
        }

        if self.data["rate"] == "":
            self.data["rate"] = utils.xml_ev(lshw, element, "capacity")

        self.name = utils.xml_ev(lshw, element, "product")
        self.model = utils.xml_ev(lshw, element, "product")
        self.serial = utils.ethtool_mac(utils.xml_ev(lshw, element, "logicalname"))
        self.vendor = utils.normalize_vendor(utils.xml_ev(lshw, element, "vendor"))
        self.firmware_version = utils.xml_ev(
            lshw, element, "configuration/setting[@id='firmware']/@value", True
        )

        if not utils.xml_ev(lshw, element, "businfo") == "":
            self.pci_id = utils.xml_ev(lshw, element, "businfo").split(":", 1)[1]
        else:
            self.pci_id = ""

        if "Illegal Vendor ID" in self.vendor and self.pci_id != "":
            _lspci = utils.lspci(self.pci_id)
            self.vendor = utils.normalize_vendor(_lspci["vendor"])
            self.model = _lspci["device"]
            self.name = self.model

        if "Mellanox" in self.vendor and self.pci_id != "":
            try:
                self.firmware_version = utils.get_mellanox_prop(
                    self.pci_id, "firmware_version"
                )
                self.data["mellanox_psid"] = utils.get_mellanox_prop(
                    self.pci_id, "psid"
                )
            except Exception:
                self.firmware_version = ""
                utils.log(message="get_mellanox_prop failed.")

    def disabled_update(self, _facility="lab1"):
        if "Mellanox" not in self.vendor:
            return

        _pci_id = "0000:" + self.pci_id

        try:
            if not utils.mlxup_upgradable(_pci_id):
                utils.log(message="Mellanox NIC already upgraded.")
                return
        except Exception:
            utils.log(message="mlxup_upgradable failed.")
            return

        _isdell = utils.mellanox_isdell(_pci_id)
        utils.log(component_type=self.component_type, pci_id=_pci_id, isdell=_isdell)

        if _isdell:
            _fw_hash = "4c01eb16b3caa839ea81405a88e06e9e37d0b9dbca2aaa333f52857a3b1196b02391b6eed2ad465a784671c40c649ab885395c083f47c0348890c997012a590d"  # noqa
            _psid = utils.get_mellanox_prop(_pci_id, "psid")
            _fw_uri = (
                "http://install."
                + _facility
                + ".packet.net/misc/osie/fw/mlx-"
                + _psid
                + ".bin"
            )
            mlxup = utils.mlxup_firmware(_pci_id, _fw_uri, _fw_hash)
        else:
            mlxup = utils.mlxup_online(_pci_id)

        self.updated = True
        utils.log(component_type=self.component_type, isdell=_isdell, output=mlxup)
