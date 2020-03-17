import utils

from lxml import etree

from component.component import Component


class Motherboard(Component):
    def __init__(self, lshw, element):
        Component.__init__(self, lshw, element)

        self.data = {
            "uuid": utils.xml_ev(
                lshw,
                lshw.getroot(),
                "node[@class='system']/configuration/setting[@id='uuid']/@value",
                True,
            ),
            "date": utils.xml_ev(lshw, element, "node[@id='firmware']/date"),
        }

        self.vendor = utils.normalize_vendor(utils.xml_ev(lshw, element, "vendor"))
        if self.vendor == "Dell Inc.":
            self.model = utils.dmidecode_string("system-product-name")
        else:
            self.model = utils.xml_ev(lshw, element, "product")

        if self.model == "X11SSE-F":
            self.model = "MBD-X11SSE-F"

        self.name = self.model
        self.serial = utils.xml_ev(lshw, element, "serial")
        self.firmware_version = utils.xml_ev(
            lshw, element, "node[@id='firmware']/version"
        )

    @classmethod
    def list(cls, lshw):
        xpath = etree.XPath("/list/node/node[@id='core']")

        motherboards = []
        for motherboard in xpath(lshw):
            motherboards.append(cls(lshw, motherboard))

        return motherboards
