"""Run the media format tests and portable Icarus RTL regressions."""
import os
from pathlib import Path
import shutil
import subprocess
import sys

root=Path(__file__).resolve().parent
portable=root/".test_deps/icarus/ucrt64/bin"
env=os.environ.copy()
env["PATH"]=str(portable)+os.pathsep+env.get("PATH","")
ivl=shutil.which("iverilog",path=env["PATH"])
vvp=shutil.which("vvp",path=env["PATH"])
subprocess.run([sys.executable,str(root/"test_video_format.py")],check=True)
if not ivl or not vvp:
    sys.exit("Icarus missing: install Icarus or prepare portable .test_deps first")
rtl=root.parent/"source_code/rtl"
tests=root/"tests"
for name,files,variants in [
    ("video_player_tb",["sd_loader.v","framebuffer.v"],[[],["+SLOT=31"],["+CAP=9437184"],
        ["+SLOT=31","+CAP=41943040"],["+BAD=1"],["+BAD=2"],["+BAD=2","+SLOT=31"],
        ["+BAD=3"],["+BAD=4"],["+ONCE=1"],["+ONCE=1","+REPLAY=1"],
        ["+DYNAMIC=1"],["+STALL=1"],["+SINGLE=1"],["+SINGLE=1","+ONCE=1"],
        ["+PRESENT=1"],["+PRESENT=1","+ONCE=1"],["+PRESENT=1","+ONCE=1","+REPLAY=1"],["+PAUSE=1"]]),
    ("photo_curtain_tb",["tf_hdmi_top.v"],[[]]),
    ("photo_slide_tb",["tf_hdmi_top.v"],[[]]),
    ("photo_push_render_tb",["framebuffer.v","vga_disp.v"],[[]]),
    ("sd_capacity_tb",["sd_card_top.v","spi_master.v"],[[],["+CACHE=1"]]),
    ("sd_spi_pins_tb",["sd_card_top.v","spi_master.v"],[[]]),
    ("framebuffer_video_tb",["framebuffer.v"],[[]]),
    ("video_presenter_tb",["framebuffer.v"],[[],["+FAULT=1"]]),
    ("video_render_tb",["framebuffer.v","vga_disp.v"],[[]]),
    ("image_loader_tb",["sd_loader.v"],[[]]),
    ("hdmi_isolation_tb",["tf_hdmi_top.v"],[[]]),
    ("video_controls_tb",["tf_hdmi_top.v","sd_loader.v","framebuffer.v","vga_disp.v",
                          "sd_card_top.v","spi_master.v"],[[]]),
    ("ui_overlay_tb",["tf_hdmi_top.v","sd_loader.v","framebuffer.v","vga_disp.v",
                      "sd_card_top.v","spi_master.v"],[[]]),
    ("photo_hold_top_tb",["tf_hdmi_top.v","sd_loader.v","framebuffer.v","vga_disp.v",
                          "sd_card_top.v","spi_master.v"],[[]]),
]:
    binary=tests/(name+".vvp")
    models=[str(tests/"framebuffer_video_tb.v")] if name in ("photo_hold_top_tb","photo_push_render_tb","video_controls_tb","ui_overlay_tb","video_presenter_tb","video_render_tb","video_player_tb") else []
    subprocess.run([ivl,"-g2012","-s",name,"-o",str(binary),str(tests/(name+".v"))]+models+
                   [str(rtl/file) for file in files],check=True,cwd=tests,env=env)
    for variant in variants:
        subprocess.run([vvp,str(binary)]+variant,check=True,cwd=tests,env=env,timeout=600 if name in ("video_render_tb","photo_push_render_tb") else 120)
print("PASS: all video-format and RTL regression tests")
