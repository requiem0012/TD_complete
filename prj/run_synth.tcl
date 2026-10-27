# Standalone synthesis + place&route script (avoids the auto-generated
# multirun_script.tcl whose import_device line TD 2026.2 emits malformed).
import_device eagle_s20.db -package EG4S20BG256
open_project {tf_hdmi_display.al}
reset_runs { syn_1 }
launch_runs { syn_1 phy_1 } -jobs 2
wait_run syn_1 -quiet
wait_run phy_1 -quiet
save_best_bits
exit
