import utils
from component.component import Component


class ManagementController(Component):
    def __init__(self):
        Component.__init__(self)

        self.data = {}

        self.model = utils.dmidecode_string("system-product-name")
        self.name = self.model + " Base Management Controller"
        self.vendor = utils.normalize_vendor(utils.get_mc_info("vendor"))
        self.serial = utils.get_mc_info("guid")
        self.firmware_version = utils.get_mc_info("firmware_version")

    @classmethod
    def list(cls, _):
        bmcs = []
        bmcs.append(cls())
        return bmcs
