DESTDIR ?= /opt/diode_node
SHELL = /bin/bash

all:
	./snap/build.sh

install:
	mkdir -p $(DESTDIR)/meta/hooks
	cp snap/configure $(DESTDIR)/meta/hooks/
	chmod +x $(DESTDIR)/meta/hooks/configure
	cp snap/hooks/remove $(DESTDIR)/meta/hooks/remove
	chmod +x $(DESTDIR)/meta/hooks/remove
	tar -x --no-same-owner -zf _build/prod/diode_node-`./scripts/version.sh`.tar.gz -C $(DESTDIR)
	cp snap/run $(DESTDIR)/bin/
	chmod +x $(DESTDIR)/bin/run
	cp scripts/snap_backup_on_remove.sh $(DESTDIR)/bin/backup_on_remove
	chmod +x $(DESTDIR)/bin/backup_on_remove
	cp scripts/restore_snap_backup.sh $(DESTDIR)/bin/restore_snap_backup
	chmod +x $(DESTDIR)/bin/restore_snap_backup
