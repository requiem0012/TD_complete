`timescale 1ns/1ps
module clk_wize(input refclk,reset,output clk0_out,output reg clk1_out=0);
    always @(posedge refclk) clk1_out<=~clk1_out;
    assign clk0_out=refclk;
endmodule
module EG_LOGIC_BUFG(input i,output o);assign o=i;endmodule
module EG_LOGIC_ODDR #(parameter ASYNCRST="ENABLE")
    (input clk,d0,d1,rst,output q);assign q=0;endmodule
module ui_overlay_tb;
    reg clk=0;always #10 clk=~clk;
    reg run=0;
    reg [9:0] sx=0,sy=0,stamp=0;
    reg [23:0] ink=24'hffffff;
    integer x,y,glyph_cell,col,row;
    reg [4:0] bits;
    reg expected_ink;
    tf_hdmi_top dut(.sys_clk(clk),.sys_rst_n(1'b1),.key_switch(1'b1),
        .key_previous(1'b1),.key_replay(1'b1),.sw1(1'b0),.sw2(1'b1),.sw3(1'b0),
        .sw4(1'b1),.SD_MISO(1'b1));
    function [4:0] digit;
        input integer d,r;
        begin
            case(d)
                1: case(r) 0:digit=4;1:digit=12;2:digit=4;3:digit=4;4:digit=4;5:digit=4;default:digit=31;endcase
                2: case(r) 0:digit=14;1:digit=17;2:digit=1;3:digit=2;4:digit=4;5:digit=8;default:digit=31;endcase
                3: case(r) 0:digit=14;1:digit=17;2:digit=1;3:digit=6;4:digit=1;5:digit=17;default:digit=14;endcase
                4: case(r) 0:digit=2;1:digit=6;2:digit=10;3:digit=18;4:digit=31;5:digit=2;default:digit=2;endcase
                default:digit=0;
            endcase
        end
    endfunction
    initial begin
        force dut.core_rst_n=run;
        repeat(5) @(negedge clk);run=1;
        force dut.video_mode_reg=1;
        force dut.video_seconds_gray=stamp;
        stamp=10'd754^(10'd754>>1);
        repeat(10) @(posedge dut.pixel_clk);
        force dut.hdmi_cx=799;force dut.hdmi_cy=524;
        repeat(16) @(posedge dut.pixel_clk);#1;
        if(dut.time_digits!==16'h1234) $fatal(1,"Elapsed timestamp is not 12:34");
        force dut.hdmi_cx=0;force dut.hdmi_cy=0;
        force dut.pattern_x=sx;force dut.pattern_y=sy;
        force dut.media_valid_sync=2'b11;
        force dut.media_error_sync=0;force dut.copy_error_sync=0;
        repeat(2) begin
            for(y=35;y<56;y=y+1) for(x=8;x<98;x=x+1) begin
                sx=x;sy=y;#1;
                glyph_cell=(x-8)/18;col=((x-8)%18)/3;row=(y-35)/3;
                bits=digit(glyph_cell==0?1:glyph_cell==1?2:glyph_cell==3?3:4,row);
                expected_ink=(glyph_cell==2)?((col==2)&&((row==2)||(row==4))):
                              ((col<5)&&bits[col<5?4-col:0]);
                if(!dut.in_time||dut.normal_rgb!==(expected_ink?ink:24'h101010))
                    $fatal(1,"Timestamp glyph/color mismatch x=%0d y=%0d got=%h expected=%h",x,y,dut.normal_rgb,expected_ink?ink:24'h101010);
            end
            force dut.video_paused=1;
            repeat(8) @(posedge dut.pixel_clk);ink=24'hffcc00;
        end
        $display("PASS timestamp 12:34 all 1890 pixels, colon, gaps, white playing / amber paused");
        $finish;
    end
    initial begin #100000;$fatal(1,"Overlay timeout");end
endmodule
