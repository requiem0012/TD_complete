`timescale 1ns/1ps
// Real top/loader/scaler/RAM test. Only the already-verified SD byte interface
// and raster blank cadence are accelerated; this is not SPI/HDMI PHY validation.
module clk_wize(input refclk,reset,output clk0_out,output reg clk1_out=0);
    always @(posedge refclk) clk1_out<=~clk1_out;
    assign clk0_out=refclk;
endmodule
module EG_LOGIC_BUFG(input i,output o);assign o=i;endmodule
module EG_LOGIC_ODDR #(parameter ASYNCRST="ENABLE")
    (input clk,d0,d1,rst,output q);assign q=0;endmodule
module photo_hold_top_tb;
    reg clk=0;always #10 clk=~clk;
    reg run=0,key2=1,key3=1,valid=0,done=0,blank=0,checking=0;
    reg [7:0] data=0;
    integer sec,byt,k,writes=0;
    tf_hdmi_top dut(.sys_clk(clk),.sys_rst_n(1'b1),.key_switch(key2),
        .key_previous(key3),.key_replay(1'b1),.sw1(1'b0),.sw2(1'b0),.sw3(1'b0),
        .sw4(1'b0),.SD_MISO(1'b1));
    defparam dut.u_key_debounce.DEBOUNCE_CNT=4;
    defparam dut.u_previous_debounce.DEBOUNCE_CNT=4;
    always @(posedge clk) if(run&&dut.fb_we) begin
        writes=writes+1;
        if(dut.photo_valid&&(dut.photo_write_bank==dut.photo_front))
            $fatal(1,"Loader overwrote currently displayed photo");
    end
    always @(posedge dut.pixel_clk) if(checking) begin
        #1;
        if(!dut.valid_sync[1]||dut.normal_rgb===24'd0)
            $fatal(1,"Black gap appeared while previous photo should remain visible");
    end
    task send_frame;
        input [15:0] color;
        input [31:0] expected_lba;
        begin
            for(sec=0;sec<118;sec=sec+1) begin
                wait(dut.photo_sd_read);
                if(dut.photo_sd_addr!==expected_lba+sec) $fatal(1,"Wrong photo sector");
                repeat(3) @(negedge clk);
                for(byt=0;byt<512;byt=byt+1) begin
                    @(negedge clk);valid=1;data=byt[0]?color[15:8]:color[7:0];
                end
                @(negedge clk);valid=0;done=1;
                @(negedge clk);done=0;
            end
            wait(dut.load_done);repeat(10) @(negedge clk);
        end
    endtask
    task finish_slide;
        input expected_front;
        input [23:0] expected_rgb;
        begin
            wait(dut.u_slide.phase==3);
            for(k=0;k<90;k=k+1) begin
                blank=1;repeat(30) @(negedge clk);
                blank=0;repeat(30) @(negedge clk);
            end
            repeat(12) @(posedge dut.pixel_clk);#1;
            if(dut.photo_front!==expected_front||dut.normal_rgb!==expected_rgb||dut.photo_offset!=0)
                $fatal(1,"Final picture/buffer incorrect: front=%b rgb=%h",dut.photo_front,dut.normal_rgb);
        end
    endtask
    initial begin
        force dut.core_rst_n=run;
        force dut.sd_init_done=1;
        force dut.sd_rx_error=0;
        force dut.sd_sec_read_data=data;
        force dut.sd_sec_read_data_valid=valid;
        force dut.sd_sec_read_end=done;
        force dut.hdmi_vblank=blank;
        // Each snapshot is treated as blank-only. Moving geometry is verified
        // separately by photo_push_render_tb across actual 800x525 rasters.
        force dut.hdmi_cx=799;force dut.hdmi_cy=500;
        repeat(8) @(negedge clk);run=1;
        send_frame(16'hf800,0);repeat(12) @(posedge dut.pixel_clk);#1;
        if(dut.normal_rgb!==24'hff0000) $fatal(1,"Initial A photo incorrect");
        checking=1;
        key2=0;repeat(30) @(negedge clk);key2=1;
        wait(!dut.load_done);repeat(300) @(negedge clk);
        if(dut.normal_rgb!==24'hff0000) $fatal(1,"Old red photo was not held while reading B");
        send_frame(16'h07e0,128);finish_slide(1,24'h00ff00);
        key3=0;repeat(30) @(negedge clk);key3=1;
        wait(!dut.load_done);repeat(300) @(negedge clk);
        if(dut.normal_rgb!==24'h00ff00) $fatal(1,"Old green B photo was not held while reading A");
        send_frame(16'h001f,0);finish_slide(0,24'h0000ff);
        if(writes!=90000) $fatal(1,"Unexpected frame write count %0d",writes);
        $display("PASS real top: 3 photos / 354 sectors / 90000 writes, no black gap, inactive-bank loads and A->B->A pushes");
        $finish;
    end
    initial begin #10000000;$fatal(1,"Top photo hold timeout");end
endmodule
