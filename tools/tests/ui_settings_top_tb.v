`timescale 1ns/1ps
module clk_wize(input refclk,reset,output clk0_out,clk1_out);assign clk0_out=0;assign clk1_out=0;endmodule
module EG_LOGIC_BUFG(input i,output o);assign o=i;endmodule
module EG_LOGIC_ODDR #(parameter ASYNCRST="ENABLE")(input clk,d0,d1,rst,output q);assign q=0;endmodule
module ui_settings_top_tb;
 reg clk=0;always #10 clk=~clk;
 reg run=0,sw2=0,sw3=0,key2=1,key3=1;
 tf_hdmi_top dut(.sys_clk(clk),.sys_rst_n(1'b1),.key_switch(key2),.key_previous(key3),
 .key_replay(1'b1),.sw1(1'b0),.sw2(sw2),.sw3(sw3),.sw4(1'b1),.SD_MISO(1'b1));
 defparam dut.u_ui_controls.DEBOUNCE_CYCLES=4;
 defparam dut.u_key_debounce.DEBOUNCE_CNT=4;
 defparam dut.u_previous_debounce.DEBOUNCE_CNT=4;
 defparam dut.u_slide.AUTO_INTERVAL_CYCLES=20000;
 task press;input previous;
 begin
  if(previous)key3=0;else key2=0;repeat(25)@(negedge clk);
  key2=1;key3=1;repeat(25)@(negedge clk);
 end endtask
 initial begin
  force dut.core_rst_n=run;force dut.sd_init_done=1;
  force dut.load_done=1;force dut.loop_enable=1;force dut.hdmi_vblank=1;
  repeat(4)@(negedge clk);run=1;repeat(30)@(negedge clk);
  if(dut.u_slide.auto_count==0)$fatal(1,"Auto was not enabled");
  sw3=1;repeat(20)@(negedge clk);
  if(!dut.settings_mode||dut.u_slide.auto_count!=0)$fatal(1,"Settings failed to freeze auto timer");
  press(0);press(0);press(0);press(1);
  if(dut.u_ui_controls.level!=6||dut.base_sector!=0||dut.photo_next||dut.photo_previous)
   $fatal(1,"Photo settings changed image / wrong brightness");
  sw3=0;repeat(20)@(negedge clk);
  if(dut.settings_mode||dut.u_slide.auto_count==0||dut.u_ui_controls.level!=6)$fatal(1,"Exit lost level or failed auto restart");
  press(1);if(dut.base_sector!=1536)$fatal(1,"Photo previous not restored");
  sw2=1;repeat(500020)@(negedge clk);
  if(!dut.video_mode||dut.video_slot!=0)$fatal(1,"Video mode regression");
  sw3=1;repeat(20)@(negedge clk);press(0);
  if(dut.video_slot!=0||dut.u_ui_controls.level!=7||dut.u_slide.auto_count)
   $fatal(1,"Video settings changed slot or photo timer ran");
  sw3=0;repeat(20)@(negedge clk);press(0);
  if(dut.video_slot!=1)$fatal(1,"Video next not restored");
  press(1);if(dut.video_slot!=0)$fatal(1,"Video previous not restored");
  $display("PASS real top SW3: brightness changes, no unwanted photo/video navigation, autoplay pause/restart, persistent level");
  $finish;
 end
 initial begin #20000000;$fatal(1,"Settings top timeout");end
endmodule
