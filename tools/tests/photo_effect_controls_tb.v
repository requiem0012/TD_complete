`timescale 1ns/1ps
module clk_wize(input refclk,reset,output clk0_out,output reg clk1_out=0);
 always @(posedge refclk)clk1_out<=~clk1_out;
 assign clk0_out=refclk;
endmodule
module EG_LOGIC_BUFG(input i,output o);assign o=i;endmodule
module EG_LOGIC_ODDR #(parameter ASYNCRST="ENABLE")
 (input clk,d0,d1,rst,output q);assign q=0;endmodule
module photo_effect_controls_tb;
 reg clk=0;always #10 clk=~clk;
 reg run=0,key4=1;
 integer i;
 tf_hdmi_top dut(.sys_clk(clk),.sys_rst_n(1'b1),.key_switch(1'b1),
  .key_previous(1'b1),.key_replay(key4),.sw1(1'b1),.sw2(1'b0),
  .sw3(1'b0),.sw4(1'b0),.SD_MISO(1'b1));
 defparam dut.u_replay_debounce.DEBOUNCE_CNT=4;
 task press;input integer expected;
 begin
  @(negedge clk);key4=0;repeat(40)@(negedge clk);
  if(dut.photo_effect!==expected)$fatal(1,"KEY4 wrong effect %d",dut.photo_effect);
  repeat(40)@(negedge clk);
  if(dut.photo_effect!==expected||dut.mode_reset!=0||dut.base_sector!=0)
   $fatal(1,"Held KEY4 retriggered, reset media or changed image");
  key4=1;repeat(40)@(negedge clk);
 end endtask
 task snapshot;
 begin
  force dut.hdmi_cx=799;force dut.hdmi_cy=500;
  repeat(12)@(negedge dut.pixel_clk);
  release dut.hdmi_cx;release dut.hdmi_cy;
 end endtask
 initial begin
  force dut.core_rst_n=run;
  repeat(5)@(negedge clk);run=1;repeat(20)@(negedge clk);
  press(1);
  force dut.photo_next=1;@(negedge clk);force dut.photo_next=0;
  repeat(3)@(negedge clk);release dut.photo_next;
  if(dut.photo_effect_active!=1)$fatal(1,"Next transition did not latch effect");
  press(2);snapshot;
  if(dut.photo_effect_active!=1||dut.effect_pix!=1||dut.effect_choice_pix!=2)
   $fatal(1,"In-flight effect changed / choice snapshot failed");
  force dut.pattern_x=8;force dut.pattern_y=35;#1;
  if(!dut.osd_active||dut.u_media_osd.panel_word!="FX DISSOLVE    KEY4 NEXT")
   $fatal(1,"Dissolve OSD not displayed");
  press(0);snapshot;
  if(dut.u_media_osd.panel_word!="FX SLIDE       KEY4 NEXT")$fatal(1,"Slide OSD failed");
  press(1);snapshot;
  if(dut.u_media_osd.panel_word!="FX PAPER PLANE KEY4 NEXT")$fatal(1,"Plane OSD failed");
  release dut.pattern_x;release dut.pattern_y;
  force dut.audio_sample_word=32'h20002000;
  repeat(600)@(negedge dut.pixel_clk);
  if(dut.wave_ring[127]!==6'sd23)$fatal(1,"Live positive waveform failed");
  force dut.audio_sample_word=32'he000e000;
  repeat(600)@(negedge dut.pixel_clk);
  if(dut.wave_ring[127]!== -6'sd23)$fatal(1,"Live negative waveform failed");
  force dut.audio_sample_word=0;
  repeat(128*521+10)@(negedge dut.pixel_clk);
  for(i=0;i<128;i=i+1)if(dut.wave_ring[i]!==0)$fatal(1,"Silence retained square wave at %d",i);
  release dut.audio_sample_word;
  $display("PASS photo KEY4 0->1->2->0, debounce/hold, image isolation, latched render choice, all FX labels, live +/- PCM and silent flat line");
  $finish;
 end
 initial begin #10000000;$fatal(1,"Effect controls timeout");end
endmodule
