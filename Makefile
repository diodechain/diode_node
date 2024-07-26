DESTDIR ?= /opt/diode_node
SHELL = /bin/bash

all:
	./scripts/snapcraft_build.sh

install:
	mkdir -p $(DESTDIR)/meta/hooks
	cp snap/configure $(DESTDIR)/meta/hooks/
	chmod +x $(DESTDIR)/meta/hooks/configure
	tar -x --no-same-owner -zf _build/prod/diode_node-`./scripts/version.sh`.tar.gz -C $(DESTDIR)
	cp snap/run $(DESTDIR)/bin/
	chmod +x $(DESTDIR)/bin/run
