import json
import utils


class Component(object):
    def __init__(self, lshw=None, element=None):
        self.component_type = self.__class__.__name__ + "Component"

        self.name = "Unknown"
        self.vendor = "Unknown"
        self.model = "Unknown"
        self.serial = "Unknown"
        self.firmware_version = ""
        self.data = {}
        self.updated = False

    def __repr__(self):
        return self.__str__()

    def __str__(self):
        return json.dumps(self.post_dict())

    def post(self, tinkerbell):
        response = utils.http_request(tinkerbell, str(self), "POST")

        if response:
            utils.log(info="Posted component to tinkerbell", body=response.read())
            return True

        return False

    @classmethod
    def post_all(cls, components, tinkerbell):
        components_json = json.dumps(
            {"components": [c.post_dict() for c in components]}
        )
        response = utils.http_request(tinkerbell, components_json, "POST")

        if response:
            utils.log(info="Posted components to tinkerbell", body=response.read())
            return True

        return False

    def update(self):
        utils.log(error="Component update method not implemented.")

    def post_dict(self):
        _post_dict = {}
        for _key, _value in self.__dict__.items():
            if _key in [
                "type",
                "name",
                "model",
                "serial",
                "vendor",
                "firmware_version",
                "data",
            ]:
                _post_dict[_key] = _value

        _post_dict["type"] = self.component_type

        return _post_dict
