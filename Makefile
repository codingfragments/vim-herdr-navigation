PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin

.PHONY: install build uninstall clean

install: build
	install -Dm755 target/release/navigate $(DESTDIR)$(BINDIR)/navigate

build:
	cargo build --release

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/navigate

clean:
	cargo clean
