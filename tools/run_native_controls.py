"""Focused regressions for the current native player, not historical fixtures."""
from run_native_tests import ROOT,TEST,sim
import sys

top=['tf_hdmi_top.v','sd_loader.v','sdram_burst.v','sdram_media.v','sd_card_top.v','spi_master.v']
sim('photo_number_tb',top,model=True)
if '--quick' not in sys.argv:
    sim('native_photo_tb',top,model=True)
    sim('video_controls_tb',top,model=True)
sim('ui_controls_tb',['tf_hdmi_top.v'])
sim('native_autoplay_tb',['tf_hdmi_top.v'])
sim('video_loop_recovery_tb',top,model=True)
sim('photo_effect_controls_tb',top,model=True)
sim('photo_effect_map_tb',['sdram_media.v'])
sim('ui_overlay_tb',top,model=True)
sim('ui_settings_top_tb',top,model=True)
