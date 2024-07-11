DESTDIR ?= /opt/diode_node

all:
	./scripts/snapcraft_build.sh

install:
	mkdir -p $(DESTDIR)
	tar -x --no-same-owner -zf _build/prod/diode_node*.tar.gz -C $(DESTDIR)
