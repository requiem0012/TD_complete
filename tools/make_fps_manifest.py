"""Record release identity; ordinary project files only, no device access."""
import hashlib,json,re
from pathlib import Path

root=Path(__file__).resolve().parent.parent
def identity(path):
    p=root/path
    return dict(path=path,bytes=p.stat().st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest())

report=(root/'prj/tf_hdmi_display_Runs/phy_1/final_timing.rpt').read_text(errors='replace')
result=dict(format='FINAL-SDRAM-native-640x480-6fps',board_tested=False,
    selected_final=True,experimental_8fps_rejected_by_user=True,
    setup_wns_ns=float(re.search(r'SWNS:\s*([-\d.]+)ns',report).group(1)),
    hold_wns_ns=float(re.search(r'HWNS:\s*([-\d.]+)ns',report).group(1)),
    files=[identity(p) for p in [
        'prj/tf_hdmi_display_FINAL_6fps.bit','prj/tf_hdmi_display.al',
        'source_code/rtl/tf_hdmi_top.v','source_code/rtl/sd_loader.v',
        'source_code/rtl/sdram_burst.v','source_code/rtl/sdram_media.v',
        'source_code/rtl/sd_card_top.v','source_code/rtl/spi_master.v',
        'source_code/adc_sdc/tf_hdmi.adc','source_code/adc_sdc/tf_hdmi.sdc',
        'tools/mp4_to_tf_video.py','tools/tf_video_card.ps1',
        'tools/demo0_6fps.bin','tools/demo1_6fps_sample.bin',
        'tools/test_native_video.py','tools/tests/native_video_file_tb.v',
        'tools/tests/photo_number_tb.v','FINAL_RELEASE.md',
        'README_6fps.md','VALIDATION_6fps.md']],
    preserved_baseline=identity('baseline_native_4fps.bit'),
    note='No physical card writes or FPGA programming performed. See README_6fps.md.')
(root/'RELEASE_6fps.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
print(json.dumps(result,indent=2))
