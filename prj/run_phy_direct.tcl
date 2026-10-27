# Run from tf_hdmi_display_Runs/phy_1, after successful current synthesis.
# Avoid the TD run-manager crash observed after exporting the gate/bit files.
if {[catch {source_tcl ./tf_hdmi_display.tcl} problem]} {
    puts "DIRECT_PHY_FAILED: $problem"
    exit
}
puts "DIRECT_PHY_COMPLETE"
exit
