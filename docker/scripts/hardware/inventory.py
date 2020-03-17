#!/usr/bin/env python3

import click
from lxml import etree
import jsonpickle

import utils

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
    help="Component type(s) to check",
    multiple=True,
    default=[cls.__name__ for cls in vars()["Component"].__subclasses__()],
)
@click.option("--tinkerbell", "-u", help="Tinkerbell uri", required=True)
@click.option(
    "--verbose",
    "-v",
    default=False,
    help="Turn on verbose messages for debugging",
    is_flag=True,
)
@click.option(
    "--dry",
    "-d",
    default=False,
    help="Don't actually post anything to API",
    is_flag=True,
)
@click.option(
    "--cache-file",
    "-c",
    default="/tmp/components.jsonpickle",
    help="Path to local json component store",
)
def hardware(component_type, tinkerbell, verbose, dry, cache_file):
    lshw = etree.ElementTree(etree.fromstring(utils.lshw()))
    components = []

    for t in component_type:
        components.extend(eval(t).list(lshw))

    if verbose:
        for component in components:
            utils.log(name=component.name, contents=component)

    with open(cache_file, "w") as output:
        output.write(jsonpickle.encode(components))

    if not dry:
        Component.post_all(components, tinkerbell)


if __name__ == "__main__":
    hardware(auto_envvar_prefix="HARDWARE")
