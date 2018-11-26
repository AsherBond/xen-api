include config.mk

OPAM_PREFIX=$(DESTDIR)$(shell opam config var prefix)
OPAM_LIBDIR=$(DESTDIR)$(shell opam config var lib)
FLAGS=--prefix=$(OPAM_PREFIX) --libdir=$(OPAM_LIBDIR)

.PHONY: release build install uninstall clean test doc reindent

release:
	dune build @install --profile=release

build:
	dune build @install

install:
	dune install $(FLAGS) message-switch-core
	dune install $(FLAGS) message-switch-unix
ifeq ($(ASYNC),--enable-async)
	dune install $(FLAGS) message-switch-async
endif
ifeq ($(LWT),--enable-lwt)
	dune install $(FLAGS) message-switch-lwt
	install -D _build/install/default/bin/message-switch $(DESTDIR)$(SBINDIR)
endif
	install -D _build/install/default/bin/message-cli $(DESTDIR)$(SBINDIR)

uninstall:
	dune uninstall $(FLAGS) message-switch-core
	dune uninstall $(FLAGS) message-switch-unix
ifeq ($(ASYNC),--enable-async)
	dune uninstall $(FLAGS) message-switch-async
endif
ifeq ($(LWT),--enable-lwt)
	dune uninstall $(FLAGS) message-switch-lwt
	rm -f $(DESTDIR)$(SBINDIR)/message-switch
endif
	rm -f $(DESTDIR)$(SBINDIR)/message-cli

clean:
	dune clean

test:
	dune runtest --no-buffer

# requires odoc
doc:
	dune build @doc

reindent:
	git ls-files '*.ml*' | xargs ocp-indent --syntax cstruct -i


.DEFAULT_GOAL := release
