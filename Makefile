UNAME := $(shell uname)
PG_INCLUDE := $(shell pg_config --includedir)
PG_LIB := $(shell pg_config --libdir)

ifeq ($(UNAME), Darwin)
  DYLIB_EXT := dylib
  CFLAGS_SHARED := -dynamiclib
else
  DYLIB_EXT := so
  CFLAGS_SHARED := -shared -fPIC
endif

CC ?= cc
CFLAGS := -O2 -Wall -Wextra -I$(PG_INCLUDE)
LDFLAGS := -L$(PG_LIB) -lpq

.PHONY: all clean

all: libkaappi_pg.$(DYLIB_EXT)

libkaappi_pg.$(DYLIB_EXT): csrc/kaappi_pg.c
	$(CC) $(CFLAGS) $(CFLAGS_SHARED) -o $@ $< $(LDFLAGS)

clean:
	rm -f libkaappi_pg.dylib libkaappi_pg.so
