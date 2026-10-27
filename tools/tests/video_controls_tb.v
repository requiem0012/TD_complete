`timescale 1ns/1ps
// Exercise the real top-level controls with pixel clocks stopped; not HDMI PHY QA.
module clk_wize(input refclk,reset,output clk0_out,clk1_out);
    assign clk0_out=0;assign clk1_out=0;
endmodule
module EG_LOGIC_BUFG(input i,output o);assign o=i;endmodule
module EG_LOGIC_ODDR #(parameter ASYNCRST="ENABLE")
    (input clk,d0,d1,rst,output q);assign q=0;endmodule

module video_controls_tb;
    reg clk=0;always #10 clk=~clk;
    reg reset_n=0,run=0,sw2=0,sw4=0,key2=1,key3=1,key4=1;
    integer replay_events=0,next_events=0;
    tf_hdmi_top dut(.sys_clk(clk),.sys_rst_n(reset_n),.key_switch(key2),
        .sw1(1'b0),.sw2(sw2),.sw3(1'b0),.sw4(sw4),.key_replay(key4),.key_previous(key3),.SD_MISO(1'b1));
    defparam dut.u_key_debounce.DEBOUNCE_CNT=4;
    defparam dut.u_replay_debounce.DEBOUNCE_CNT=4;
    defparam dut.u_previous_debounce.DEBOUNCE_CNT=4;
    defparam dut.u_pause_debounce.DEBOUNCE_CNT=4;
    always @(posedge clk) if(run) begin
        if(dut.replay_press) replay_events=replay_events+1;
        if(dut.key_press) next_events=next_events+1;
    end
    initial begin
        force dut.core_rst_n=run;
        repeat(4) @(negedge clk);reset_n=1;run=1;
        sw2=1;repeat(500010) @(negedge clk);
        if(!dut.video_mode||dut.video_slot!=0) $fatal(1,"SW2 did not enter slot 1");
        sw4=1;repeat(30) @(negedge clk);
        sw4=0;repeat(30) @(negedge clk);
        if(dut.loop_enable) $fatal(1,"SW4 bounce accepted");
        sw4=1;repeat(500010) @(negedge clk);
        if(!dut.loop_enable) $fatal(1,"SW4 stable high not accepted");
        key2=0;repeat(30) @(negedge clk);
        key2=1;repeat(30) @(negedge clk);
        if(dut.video_slot!=1||next_events!=1) $fatal(1,"KEY2 slot switch failed");
        reset_n=0;repeat(30) @(negedge clk);
        if(!dut.video_paused||!dut.reset_key_n||dut.mode_reset!=0)
            $fatal(1,"KEY1 did not pause / accidentally reset video");
        repeat(30) @(negedge clk);
        if(!dut.video_paused) $fatal(1,"Held KEY1 toggled pause twice");
        reset_n=1;repeat(30) @(negedge clk);
        reset_n=0;repeat(30) @(negedge clk);reset_n=1;repeat(30) @(negedge clk);
        if(dut.video_paused) $fatal(1,"KEY1 did not resume");
        key3=0;repeat(30) @(negedge clk);key3=1;repeat(30) @(negedge clk);
        if(dut.video_slot!=0) $fatal(1,"KEY3 did not select previous video");
        key3=0;repeat(30) @(negedge clk);key3=1;repeat(30) @(negedge clk);
        if(dut.video_slot!=31) $fatal(1,"KEY3 did not wrap slot 1 to 32");
        key2=0;repeat(30) @(negedge clk);key2=1;repeat(30) @(negedge clk);
        key2=0;repeat(30) @(negedge clk);key2=1;repeat(30) @(negedge clk);
        key4=0;
        wait(dut.replay_press);@(posedge clk);#1;
        if(dut.mode_reset!=15||dut.video_slot!=1||dut.media_rst_n)
            $fatal(1,"KEY4 did not reset current slot safely");
        repeat(100) @(negedge clk);
        if(dut.mode_reset!=0||replay_events!=1||dut.video_slot!=1)
            $fatal(1,"Held KEY4 retriggered or changed slot");
        key4=1;repeat(30) @(negedge clk);
        sw4=0;repeat(500010) @(negedge clk);
        if(dut.loop_enable) $fatal(1,"SW4 low did not disable loop");
        sw2=0;repeat(500010) @(negedge clk);
        key4=0;repeat(30) @(negedge clk);
        if(dut.video_mode||dut.mode_reset!=0||dut.video_slot!=0)
            $fatal(1,"KEY4 affected photo mode");
        reset_n=0;#1;
        if(dut.reset_key_n) $fatal(1,"KEY1 photo reset was lost");
        $display("PASS real top SW4, KEY4 replay, KEY3 previous/wrap, KEY1 pause/resume/photo reset");
        $finish;
    end
    initial begin #60000000;$fatal(1,"Controls timeout");end
endmodule
