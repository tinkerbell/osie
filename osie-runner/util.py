import re


def value_from_kopt(cmdline, key):
    match = re.search(r"\b" + re.escape(key) + r"=(\S+)", cmdline)

    if match is not None:
        return match.group(1)

    return None
