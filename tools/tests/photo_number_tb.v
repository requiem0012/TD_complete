`timescale 1ns/1ps
module clk_wize(input refclk,reset,output clk0_out,output reg clk1_out=0);
    always @(posedge refclk)clk1_out<=~clk1_out;
    assign clk0_out=refclk;
endmodule
module EG_LOGIC_BUFG(input i,output o);assign o=i;endmodule
module EG_LOGIC_ODDR #(parameter ASYNCRST="ENABLE")
    (input clk,d0,d1,rst,output q);assign q=0;endmodule
module photo_number_tb;
    reg clk=0;always #10 clk=~clk;
    reg run=0,n=0,p=0;
    reg [9:0] x=62,y=8;
    integer checks=0,row,col;
    reg [4:0] expected;
    tf_hdmi_top dut(.sys_clk(clk),.sys_rst_n(1'b1),.key_switch(1'b1),
        .key_previous(1'b1),.key_replay(1'b1),.sw1(1'b0),.sw2(1'b0),
        .sw3(1'b0),.sw4(1'b0),.SD_MISO(1'b1));
    function [4:0] digit;
        input integer d,r;
        begin case(d)
            1:case(r)0:digit=4;1:digit=12;2:digit=4;3:digit=4;4:digit=4;5:digit=4;default:digit=31;endcase
            2:case(r)0:digit=14;1:digit=17;2:digit=1;3:digit=2;4:digit=4;5:digit=8;default:digit=31;endcase
            3:case(r)0:digit=14;1:digit=17;2:digit=1;3:digit=6;4:digit=1;5:digit=17;default:digit=14;endcase
            4:case(r)0:digit=2;1:digit=6;2:digit=10;3:digit=18;4:digit=31;5:digit=2;default:digit=2;endcase
            default:digit=0;
        endcase end
    endfunction
    task check_number;
        input integer number;
        begin
            repeat(6)@(negedge dut.pixel_clk);
            if(dut.base_sector!==(number-1)*512||dut.image_number!==number)
                $fatal(1,"Photo number mapping base=%0d number=%0d expected=%0d",dut.base_sector,dut.image_number,number);
            for(row=0;row<7;row=row+1)begin
                expected=digit(number,row);
                for(col=0;col<6;col=col+1)begin
                    x=62+col*3;y=8+row*3;#1;
                    if(dut.char_code!==number||dut.glyph_bits!==expected)
                        $fatal(1,"Photo glyph mismatch number=%0d row=%0d",number,row);
                    if(dut.text_px!==((col<5)?expected[4-col]:1'b0))
                        $fatal(1,"Photo glyph pixel mismatch number=%0d row=%0d col=%0d",number,row,col);
                    checks=checks+1;
                end
            end
        end
    endtask
    task change;
        input previous;input integer number;
        begin
            @(negedge clk);p=previous;n=!previous;
            @(negedge clk);p=0;n=0;
            check_number(number);
        end
    endtask
    initial begin
        force dut.core_rst_n=run;force dut.photo_rst_n=run;
        force dut.sd_init_done=1;force dut.load_ack=1;
        force dut.photo_next=n;force dut.photo_previous=p;
        force dut.pattern_x=x;force dut.pattern_y=y;force dut.video_mode_pix=0;
        repeat(5)@(negedge clk);run=1;
        check_number(1);change(0,2);change(0,3);change(0,1);
        change(1,3);change(1,2);change(1,1);
        $display("PASS photo number: 1->2->3->1, previous wrap, actual slot addresses, %0d independent font pixel checks",checks);
        $finish;
    end
    initial begin #100000;$fatal(1,"Photo-number test timeout");end
endmodule
