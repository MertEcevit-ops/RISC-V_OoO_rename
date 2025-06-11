SV_FILES = ${wildcard ./src/pkg/typedefs.sv} ${wildcard ./src/rename.sv}
TB_FILES = ${wildcard ./tb/tb_rename.sv}
ALL_FILES = ${SV_FILES} ${TB_FILES}

lint:
	@echo "Running lint checks..."
	@echo "Linting files: ${SV_FILES}"
	verilator --lint-only --timing -Wall -Wno-UNUSED -Wno-CASEINCOMPLETE ${SV_FILES}

build:
	@echo "Building with files: ${SV_FILES} ${TB_FILES}"
	verilator --binary ${SV_FILES} ${TB_FILES} --top tb_rename -j 0 --trace -Wno-CASEINCOMPLETE 

run: build
	@echo "Running simulation..."
	obj_dir/Vtb_rename

wave: run
	@echo "Opening waveform viewer..."
	gtkwave --dark dump.vcd

clean:
	@echo "Cleaning temp files..."
	rm -f dump.vcd
	rm -rf obj_dir

help:
	@echo "Available targets:"
	@echo "  lint  - Run Verilator lint checks"
	@echo "  build - Build simulation executable"
	@echo "  run   - Build and run simulation"
	@echo "  wave  - Run simulation and open waveform viewer"
	@echo "  clean - Remove generated files"
	@echo "  help  - Show this help message"

# Debug target to show file lists
debug:
	@echo "Package files: ${PKG_FILES}"
	@echo "Source files: ${SRC_FILES}"
	@echo "Testbench files: ${TB_FILES}"
	@echo "All SV files: ${SV_FILES}"
	@echo "All files: ${ALL_FILES}"

.PHONY: lint build run wave clean help debug