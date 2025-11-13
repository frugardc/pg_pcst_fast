# PostgreSQL extension Makefile for pcst_fast

EXTENSION = pcst_fast
DATA = pcst_fast--1.0.0.sql
MODULE_big = pcst_fast

# Source files
OBJS = src/pcst_fast_pg.o src/pcst_fast_c_wrapper.o src/pcst_fast.o

# Compiler flags
override CFLAGS := $(filter-out -fexcess-precision=standard -Wmissing-prototypes -Wdeclaration-after-statement,$(CFLAGS))
override CXXFLAGS := $(filter-out -fexcess-precision=standard -Wmissing-prototypes -Wdeclaration-after-statement,$(CXXFLAGS))

# Add required flags for C++
CXXFLAGS += -std=c++11 -fPIC
SHLIB_LINK = -lstdc++

# PostgreSQL extension build framework
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)

# Custom compilation rules
%.o : %.cpp
	$(CXX) $(CXXFLAGS) $(CPPFLAGS) -fPIC -I$(shell $(PG_CONFIG) --includedir-server) -c -o $@ $<

%.o : %.cc
	$(CXX) $(CXXFLAGS) $(CPPFLAGS) -fPIC -I$(shell $(PG_CONFIG) --includedir-server) -c -o $@ $<

# Custom bitcode compilation rules for LLVM
%.bc : %.cpp
	$(CLANG) -xc++ $(BITCODE_CXXFLAGS) $(CPPFLAGS) -fPIC -I$(shell $(PG_CONFIG) --includedir-server) -flto=thin -emit-llvm -c -o $@ $<

%.bc : %.cc
	$(CLANG) -xc++ $(BITCODE_CXXFLAGS) $(CPPFLAGS) -fPIC -I$(shell $(PG_CONFIG) --includedir-server) -flto=thin -emit-llvm -c -o $@ $<

include $(PGXS)

# Specific compilation rules
src/pcst_fast_pg.o: src/pcst_fast_pg.c
	$(CC) $(CFLAGS) $(CPPFLAGS) -fPIC -I$(shell $(PG_CONFIG) --includedir-server) -c -o $@ $<

src/pcst_fast_c_wrapper.o: src/pcst_fast_c_wrapper.cpp
	$(CXX) $(CXXFLAGS) $(CPPFLAGS) -fPIC -I$(shell $(PG_CONFIG) --includedir-server) -c -o $@ $<

src/pcst_fast.o: src/pcst_fast.cc
	$(CXX) $(CXXFLAGS) $(CPPFLAGS) -fPIC -I$(shell $(PG_CONFIG) --includedir-server) -c -o $@ $<

# Bitcode compilation rules
src/pcst_fast_c_wrapper.bc: src/pcst_fast_c_wrapper.cpp
	$(CLANG) -xc++ $(BITCODE_CXXFLAGS) $(CPPFLAGS) -fPIC -I$(shell $(PG_CONFIG) --includedir-server) -flto=thin -emit-llvm -c -o $@ $<

src/pcst_fast.bc: src/pcst_fast.cc
	$(CLANG) -xc++ $(BITCODE_CXXFLAGS) $(CPPFLAGS) -fPIC -I$(shell $(PG_CONFIG) --includedir-server) -flto=thin -emit-llvm -c -o $@ $<