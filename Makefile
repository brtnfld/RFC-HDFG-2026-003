#
# Makefile
#

LATEXMK=latexmk -bibtex

MAIN=RFC-HDFG-2026-003

TEXFILES=$(wildcard *.tex)

all: $(TEXFILES)
	@$(LATEXMK) -e '$$pdflatex=q/pdflatex %O -shell-escape %S/' -pdf $(MAIN)

force:
	@$(LATEXMK) -f -pdf $(MAIN)

clean:
	@$(LATEXMK) -c

distclean: clean
	@$(LATEXMK) -C

help:
	@echo -e "Usage : make [target]\n\
	all		produce PDF (default)\n\
	force		force compilation if possible\n\
	clean		clean unnecessary files\n\
	distclean	clean deeper\n\
	help		display this help"
