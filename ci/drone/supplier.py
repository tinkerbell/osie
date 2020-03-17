#!/usr/bin/env python

from __future__ import print_function

import json
import os

import packet

m = packet.Manager(os.getenv("PACKET_API_TOKEN"))
c = m.get_capacity()
cap = {}

for fac in c:
    for plan, v in c[fac].items():
        p = cap.get(plan, {})
        level = v["level"]
        lvl = p.get(level, [])
        lvl.append(fac)
        p[level] = lvl
        cap[plan] = p

print(json.dumps(cap))
