import utils

from lxml import etree

from component.component import Component


class Processor(Component):
    @classmethod
    def list(cls, lshw):
        xpath = etree.XPath("/list/node/node[1]/node[@class='processor']")

        processors = []
        for processor in xpath(lshw):
            _name = utils.xml_ev(lshw, processor, "product")
            if _name.startswith("cpu") or _name.startswith("l2-cache"):
                continue
            processors.append(cls(lshw, processor))

        return processors

    def __init__(self, lshw, element):
        Component.__init__(self, lshw, element)

        self.data = {
            "cores": utils.xml_ev(
                lshw, element, "configuration/setting[@id='cores']/@value", True
            ),
            "clock": utils.xml_ev(lshw, element, "capacity"),
        }

        self.name = utils.xml_ev(lshw, element, "product")
        self.model = utils.xml_ev(lshw, element, "version")
        self.vendor = utils.normalize_vendor(utils.xml_ev(lshw, element, "vendor"))
        self.serial = utils.xml_ev(lshw, element, "slot")
        self.firmware_version = "N/A"
