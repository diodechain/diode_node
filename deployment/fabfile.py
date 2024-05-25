# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
import binascii
import os
import time
from collections import defaultdict
from datetime import datetime
from fabric.api import env, run, cd, put, get, abort, hide, local, lcd, prefix, hosts, sudo
from fabric.contrib.files import exists


env.diode="/opt/diode_node"

# Install on Ubuntu 18.04
# fab install --host=root@eu2.prenet.diode.io
def install():
  run("mkdir -p {}".format(env.diode))
  with cd(env.diode):
    h = local("sha1sum ../_build/prod/diode_node.tar.gz", capture=True).split()[0]
    if not exists("diode_node.tar.gz") or h != run("sha1sum diode_node.tar.gz").split()[0]:
      put("../_build/prod/diode_node.tar.gz", env.diode)
    run("tar xzf diode_node.tar.gz")
    #run("bin/diode_node stop")

