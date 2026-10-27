# 50 MHz board oscillator. This file MUST appear in the project's SDC list.
create_clock -name SYS_CLK -period 20.000 -waveform {0.000 10.000} [get_ports {sys_clk}]
# Conservative generated-clock model: shortest interval is 1041 system cycles.
# The actual fractional accumulator alternates 1041/1042 cycles (48 kHz average).
# keep on audio_clk in RTL preserves a stable constraint target.
create_generated_clock -name AUDIO_SAMPLE -source [get_ports {sys_clk}] -divide_by 1041 [get_nets {audio_clk}]
# TD explicitly requested this in USR-6125: derive PLL output clocks.
derive_clocks
