import utils

from lxml import etree

from component.component import Component


class DiskController(Component):
    def __init__(self, lshw, element):
        Component.__init__(self, lshw, element)

        self.name = utils.xml_ev(lshw, element, "description")
        self.model = utils.xml_ev(lshw, element, "product")
        self.serial = utils.xml_ev(lshw, element, "businfo")
        self.vendor = utils.normalize_vendor(utils.xml_ev(lshw, element, "vendor"))
        self.firmware_version = utils.xml_ev(lshw, element, "version")

        self.data = {
            "driver": utils.xml_ev(
                lshw, element, "configuration/setting[@id='driver']/@value", True
            )
        }

        if "MegaRAID" in self.model:
            self.serial = utils.get_megaraid_prop("serial")

            for prop in (
                "product_name",
                "firmware_bios",
                "firmware_ctrlr",
                "firmware_fw",
                "firmware_nvdata",
                "firmware_boot",
                "bbu",
                "memory_size",
            ):
                self.data["megaraid_" + prop] = utils.get_megaraid_prop(prop)

    @classmethod
    def list(cls, lshw):
        xpath = etree.XPath("//node[@class='storage'][@handle!='']")

        disk_controllers = []
        for disk_controller in xpath(lshw):
            if (
                utils.xml_ev(lshw, disk_controller, "description")
                == "Non-Volatile memory controller"
            ):
                continue

            disk_controllers.append(cls(lshw, disk_controller))
        return disk_controllers

    def update(self, _facility="lab1"):
        if self.vendor != "LSI Logic" or self.model.startswith("SAS3008"):
            return

        try:
            out = utils.cmd_output(
                "MegaCli64", "-AdpFwFlash", "-f", "/tmp/smc3108.rom", "-a0"
            )
            utils.log(component_type=self.component_type, output=out)
        except Exception as e:
            utils.log(
                "ignoring update error", component_type=self.component_type, exception=e
            )
