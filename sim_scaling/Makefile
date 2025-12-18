# Makefile for vin_scaler_2x simulation

RTLDIR := ../rtl/spartan6
MULIBDIR := ../rtl/mulib/rtl

VERILATOR := verilator
VFLAGS := -Wall -Wno-fatal --trace -cc \
    -I$(RTLDIR) \
    -I$(MULIBDIR) \
    -I$(MULIBDIR)/baseip \
    -I$(MULIBDIR)/baseip/generic \
    -Wno-PINCONNECTEMPTY \
    -Wno-UNUSEDSIGNAL \
    +define+SIMULATION=1

VOBJ := obj_dir

CXX := g++
CXXFLAGS := -std=c++17 -Wall -g -O2

# Verilator include path
VINCD := $(shell verilator -getenv VERILATOR_ROOT)/include

.PHONY: all clean run

all: sim_scaling

# Build the Verilated model
$(VOBJ)/Vvin_scaler_2x.mk: $(RTLDIR)/vin_scaler_2x.v $(RTLDIR)/line_repeat.v
	$(VERILATOR) $(VFLAGS) --top-module vin_scaler_2x \
		$(RTLDIR)/vin_scaler_2x.v \
		$(RTLDIR)/line_repeat.v \
		$(MULIBDIR)/baseip/generic/mu_fifo_async.v \
		$(MULIBDIR)/baseip/mu_drsync.v \
		$(MULIBDIR)/baseip/generic/mu_dsync.v \
		$(MULIBDIR)/baseip/mu_ram_1rw.v

$(VOBJ)/Vvin_scaler_2x__ALL.a: $(VOBJ)/Vvin_scaler_2x.mk
	make -C $(VOBJ) -f Vvin_scaler_2x.mk

# Build the testbench
sim_scaling: tb_vin_scaler.cpp $(VOBJ)/Vvin_scaler_2x__ALL.a
	$(CXX) $(CXXFLAGS) -I$(VOBJ) -I$(VINCD) -I$(VINCD)/vltstd \
		tb_vin_scaler.cpp \
		$(VINCD)/verilated.cpp \
		$(VINCD)/verilated_vcd_c.cpp \
		$(VOBJ)/Vvin_scaler_2x__ALL.a \
		-o sim_scaling

run: sim_scaling
	./sim_scaling

clean:
	rm -rf $(VOBJ) sim_scaling scaling_trace.vcd
