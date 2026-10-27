# Run from tf_hdmi_display_Runs/syn_1 using the generated project/settings.
if {[catch {source_tcl ./tf_hdmi_display.tcl} problem]} {
    puts "DIRECT_SYN_FAILED: $problem"
    exit
}
puts "DIRECT_SYN_COMPLETE"
exit
