`timescale 1ns/1ps
// Digital HDMI core check only; serial I/O voltage/jitter is not modeled.
module EG_LOGIC_ODDR #(parameter ASYNCRST="ENABLE")
    (input clk,d0,d1,rst,output q);assign q=0;endmodule

module hdmi_probe #(parameter START_ROW=0)
    (input pixel,serial_clk,audio,reset,output reg finished=0);
    wire [9:0] cx,cy;
    wire [23:0] rgb={cx[7:0],cy[7:0],(cx[7:0]^cy[7:0])};
    reg [31:0] pcm=32'h1234abcd;
    wire [2:0] lanes;wire lane_clock;
    hdmi #(.VIDEO_ID_CODE(1),.VIDEO_REFRESH_RATE(60.0),.AUDIO_RATE(48000),
        .AUDIO_BIT_WIDTH(16),.START_Y(START_ROW)) dut(
        .clk_pixel_x5(serial_clk),.clk_pixel(pixel),.clk_audio(audio),.reset(reset),
        .rgb(rgb),.audio_sample_word(pcm),.tmds(lanes),.tmds_clock(lane_clock),
        .cx(cx),.cy(cy),.frame_width(),.frame_height(),.screen_width(),.screen_height());
    always @(negedge audio) pcm<={pcm[30:0],pcm[31]^pcm[21]^pcm[1]^pcm[0]};
    integer cycles=0,checked=0,islands=0,c;
    reg [9:0] previous_x=0,previous_y=0;
    reg [9:0] sampled_x,sampled_y;
    reg [2:0] mode_before;
    reg [23:0] data_before;
    function [7:0] decode;
        input [9:0] code;
        reg [7:0] q;
        integer bit_no;
        begin
            q=code[9]?~code[7:0]:code[7:0];decode[0]=q[0];
            for(bit_no=1;bit_no<8;bit_no=bit_no+1)
                decode[bit_no]=code[8]?(q[bit_no]^q[bit_no-1]):~(q[bit_no]^q[bit_no-1]);
        end
    endfunction
    always @(posedge pixel) begin
        if(!reset&&!finished) begin
            mode_before=dut.mode;data_before=dut.video_data;
            sampled_x=cx;sampled_y=cy;
            #1;
            if(cycles>4) begin
                if((previous_x<640)&&(previous_y<480)) begin
                    if(dut.mode!=1) $fatal(1,"Audio/guard entered active video at %0d,%0d",previous_x,previous_y);
                end else if(dut.mode==1) $fatal(1,"Video mode escaped into blanking");
                if(mode_before==1) begin
                    for(c=0;c<3;c=c+1)
                        if(decode(dut.tmds_internal[c*10+:10])!==data_before[c*8+:8])
                            $fatal(1,"TMDS video coding mismatch row=%0d channel=%0d",START_ROW,c);
                    checked=checked+1;
                end
                if(dut.mode==3) islands=islands+1;
            end
            previous_x=sampled_x;previous_y=sampled_y;
            cycles=cycles+1;
            if(cycles==4000) begin
                if(!islands||!checked) $fatal(1,"Insufficient video/island coverage");
                $display("PASS HDMI digital row=%0d video_pixels=%0d island_pixels=%0d no active-video overlap",START_ROW,checked,islands);
                finished=1;
            end
        end
    end
endmodule

module hdmi_isolation_tb;
    reg pixel=0,serial_clk=0,audio=0,reset=1;
    always #20 pixel=~pixel;
    always #4 serial_clk=~serial_clk;
    always #10416.666 audio=~audio;
    wire a,b,c;
    hdmi_probe #(.START_ROW(0)) p0(pixel,serial_clk,audio,reset,a);
    hdmi_probe #(.START_ROW(478)) p1(pixel,serial_clk,audio,reset,b);
    hdmi_probe #(.START_ROW(524)) p2(pixel,serial_clk,audio,reset,c);
    initial begin #101;reset=0;wait(a&&b&&c);$finish;end
    initial begin #1000000;$fatal(1,"HDMI check timeout");end
endmodule
