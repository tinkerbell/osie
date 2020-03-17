#!/usr/bin/env python3

import click
import jsonpickle

from component.component import Component  # noqa
from component.motherboard import Motherboard  # noqa
from component.processor import Processor  # noqa
from component.memory import Memory  # noqa
from component.network import Network  # noqa
from component.disk_controller import DiskController  # noqa
from component.disk import Disk  # noqa
from component.management_controller import ManagementController  # noqa


@click.command()
@click.option(
    "--component-type",
    "-t",
    help="Component type(s) to update",
    multiple=True,
    default=[cls.__name__ for cls in vars()["Component"].__subclasses__()],
)
@click.option(
    "--verbose",
    "-v",
    default=False,
    help="Turn on verbose messages for debugging",
    is_flag=True,
)
@click.option(
    "--dry", "-d", default=False, help="Don't actually update anything", is_flag=True
)
@click.option(
    "--cache-file",
    "-c",
    default="/tmp/components.jsonpickle",
    help="Path to local json component store",
)
@click.option("--facility", "-f", default="lab1", help="Packet facility code")
def update(component_type, verbose, dry, cache_file, facility):
    with open(cache_file, "r") as pickle_file:
        components = jsonpickle.decode(pickle_file.read())

    if not dry:
        for component in components:
            if component.component_type in [t + "Component" for t in component_type]:
                component.update()


if __name__ == "__main__":
    update(auto_envvar_prefix="HARDWARE")
