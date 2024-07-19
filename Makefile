DESTDIR ?= /opt/diode_node
SHELL = /bin/bash
VSN = `git describe --tags | cut -b2-`

all:
	./scripts/snapcraft_build.sh

install:
	mkdir -p $(DESTDIR)/meta/hooks
	cp snap/configure $(DESTDIR)/meta/hooks/
	chmod +x $(DESTDIR)/meta/hooks/configure
	tar -x --no-same-owner -zf _build/prod/diode_node-$(VSN).tar.gz -C $(DESTDIR)
	cp snap/run $(DESTDIR)/bin/
	chmod +x $(DESTDIR)/bin/run
