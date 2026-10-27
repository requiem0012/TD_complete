`timescale 1ns/1ps
// Control-only regression. No claim of HDMI PHY / physical SDRAM validation.
module clk_wize(input refclk,reset,output clk0_out,clk1_out);
 assign clk0_out=0;assign clk1_out=0;
endmodule
module EG_LOGIC_BUFG(input i,output o);assign o=i;endmodule
module EG_LOGIC_ODDR #(parameter ASYNCRST="ENABLE")
 (input clk,d0,d1,rst,output q);assign q=0;endmodule
module video_loop_recovery_tb;
 reg clk=0;always #10 clk=~clk;
 reg run=0,mode=0;
 tf_hdmi_top dut(.sys_clk(clk),.sys_rst_n(1'b1),.key_switch(1'b1),
 .key_previous(1'b1),.key_replay(1'b1),.sw1(1'b0),.sw2(mode),
 .sw3(1'b0),.sw4(1'b0),.SD_MISO(1'b1));
 initial begin
 force dut.core_rst_n=run;
 repeat(4)@(negedge clk);run=1;mode=1;
 repeat(500030)@(negedge clk);
 if(!dut.media_rst_n)$fatal(1,"Video mode did not initialize");
 force dut.video_we=0;force dut.video_seconds_gray=0;
 force dut.video_swap_request=0;force dut.video_stopped=0;
 force dut.loop_enable=0;
 dut.video_stall_count=249999990;
 repeat(30)@(negedge clk);
 if(dut.mode_reset!=0||dut.video_stall_count!=0)$fatal(1,"One-shot watchdog fired");
 force dut.loop_enable=1;
 force dut.video_paused=1;dut.video_stall_count=249999990;
 repeat(30)@(negedge clk);
 if(dut.mode_reset!=0||dut.video_stall_count!=0)$fatal(1,"Paused watchdog fired");
 release dut.video_paused;dut.video_paused=0;
 dut.video_stall_count=249999990;
 wait(dut.mode_reset==15);#1;
 if(dut.media_rst_n||dut.memory_rst_n||dut.video_slot!=0)
 $fatal(1,"Stall did not reset all media domains / changed slot");
 wait(dut.mode_reset==0);repeat(3)@(negedge clk);
 // Real progress must cancel the timeout, even just before expiry.
 dut.video_stall_count=249999998;force dut.video_we=1;
 repeat(3)@(negedge clk);
 if(dut.mode_reset!=0||dut.video_stall_count!=0)$fatal(1,"Progress did not cancel watchdog");
 force dut.video_we=0;
 force dut.loop_enable=0;force dut.video_stopped=1;
 repeat(10)@(negedge clk);
 if(dut.mode_reset!=0)$fatal(1,"One-shot EOF auto-restarted");
 force dut.loop_enable=1;
 @(posedge clk);#1;
 if(dut.mode_reset!=15||dut.media_rst_n||dut.video_slot!=0)
 $fatal(1,"Enabling loop at EOF did not safely restart same slot");
 force dut.video_stopped=0;
 wait(dut.mode_reset==0);repeat(5)@(negedge clk);
 if(dut.mode_reset!=0)$fatal(1,"Reset retriggered");
 $display("PASS loop recovery: 5s threshold, full reset, slot preserved, pause/once exclusion, heartbeat cancellation, enable-loop-after-EOF");
 $finish;
 end
 initial begin #30000000;$fatal(1,"Timeout");end
endmodule
