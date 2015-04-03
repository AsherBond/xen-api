
include config.mk

build: setup.data
	rm -f configure.cmo configure.cmi
	ocaml setup.ml -build

setup.data: setup.ml
	rm -f configure.cmo configure.cmi
	ocaml setup.ml -configure ${ENABLE_XENSERVER}

.PHONY: clean
clean: setup.data
	rm -f configure.cmo configure.cmi
	ocaml setup.ml -clean

install: build
	mkdir -p ${BINDIR}
	install -m 755 main.native ${BINDIR}/vhd-tool || echo "Failed to install vhd-tool"
	mkdir -p ${LIBEXECDIR}
	install -m 755 sparse_dd.native ${LIBEXECDIR}/sparse_dd || echo "Failed to install sparse_dd"
	mkdir -p ${ETCDIR}
	install -m 644 src/sparse_dd.conf ${ETCDIR}/sparse_dd.conf || echo "Failed to install sparse_dd.conf"

.PHONY: uninstall
uninstall:
	rm -f ${BINDIR}/vhd-tool
	rm -f ${LIBEXECDIR}/sparse_dd
	rm -f ${ETCDIR}/sparse_dd.conf

config.mk:
	@echo Running './configure' with the defaults
	./configure

.PHONY: distclean
distclean: clean
	rm -f config.mk
