.PHONY: all clean install build distclean
all: build doc

NAME=xcp-inventory
J=4

export OCAMLRUNPARAM=b

setup.ml:
	oasis setup

setup.bin: setup.ml lib/xcp_inventory_config.ml
	@ocamlopt.opt -o $@ $< || ocamlopt -o $@ $< || ocamlc -o $@ $<
	@rm -f setup.cmx setup.cmi setup.o setup.cmo

setup.data: setup.bin
	@./setup.bin -configure --enable-tests

build: setup.data setup.bin
	@./setup.bin -build -j $(J)

doc: setup.data setup.bin
	@./setup.bin -doc -j $(J)

install: setup.bin
	@./setup.bin -install

uninstall:
	@ocamlfind remove $(NAME) || true

test: setup.bin build
	@./setup.bin -test

reinstall: setup.bin
	@ocamlfind remove $(NAME) || true
	@./setup.bin -reinstall

clean:
	@ocamlbuild -clean
	@rm -f setup.data setup.log setup.bin

lib/xcp_inventory_config.ml:
	@echo "You need to run configure first"
	@exit 1

real-configure: configure.ml
	ocamlfind ocamlc -linkpkg -package findlib,cmdliner -o real-configure configure.ml
	@rm -f configure.cm*

distclean: clean
	rm -f lib/xcp_inventory_config.ml
