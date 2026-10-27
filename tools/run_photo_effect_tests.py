"""Three photo transitions, KEY4 selection and live-scope regressions.

python run_photo_effect_tests.py --full
No physical TF, FPGA or Flash access. --full includes cached SDRAM pixel QA.
"""
import argparse
from run_native_tests import TEST, fixture, sim

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--full', action='store_true')
args = parser.parse_args()
top = ['tf_hdmi_top.v', 'sd_loader.v', 'sdram_burst.v', 'sdram_media.v',
       'sd_card_top.v', 'spi_master.v']
sim('photo_effect_controls_tb', top, model=True)
sim('photo_effect_map_tb', ['sdram_media.v'])
sim('plane_3d_geometry_tb', ['sdram_media.v'])
sim('native_autoplay_tb', ['tf_hdmi_top.v'])
sim('video_controls_tb', top, model=True)
if args.full:
    if not all((TEST / name).exists() for name in
               ('native_a.hex', 'native_b.hex', 'native_ga.hex', 'native_gb.hex')):
        fixture()
    sim('native_memory_tb', ['sdram_burst.v', 'sdram_media.v'],
        args=('+effects',), model=True)
