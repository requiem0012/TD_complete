`timescale 1ns/1ps
module hd_presenter_tb;
    reg clk=0,pixel=0;always #10 clk=~clk;always #20 pixel=~pixel;
    reg reset_n=0,blank=1,request=0,we=0;
    reg [14:0] wa=0;reg [15:0] wd=0;
    wire ack,fw,busy,error;
    wire [10:0] ba;
    wire [14:0] fa;
    wire [15:0] fd;
    wire [63:0] b0,b1,b2,b3,p0,p1,p2,p3;
    reg [10:0] ra=0;
    integer fault_arg=0;
    wire [63:0] checked_b0=b0^((fault_arg&&fa==96)?16'h0001:16'h0000);
    bc1_framebuffer #(.USE_32K(1)) back(clk,we,wa,wd,pixel,ra,ra,ra,ra,,,,,ba,b0,b1,b2,b3);
    bc1_framebuffer front(clk,fw,fa,fd,pixel,ra,ra,ra,ra,p0,p1,p2,p3,11'd0,,,,);
    video_frame_presenter dut(clk,reset_n,blank,request,ack,ba,checked_b0,b1,b2,b3,fw,fa,fd,busy,error,we,wa,wd);
    integer frame,i,j,x,y,seed,writes=0,cycles=0;
    reg [63:0] e0,e1,e2,e3;
    function [63:0] block_value;input integer x,y;integer k;reg [15:0] w;begin
      for(k=0;k<4;k=k+1)begin w=((y*104+x)*4+k)^seed;block_value[k*16+:16]=w;end
    end endfunction
    always @(posedge clk) if(reset_n) begin
        if(busy) cycles=cycles+1;
        if(we&&busy) $fatal(1,"Back RAM written during copy");
        if(fw) begin
            if(!blank) $fatal(1,"Front RAM overwritten during active video");
            if(fa!==writes||fd!==(writes^seed^((fault_arg&&writes==96)?1:0)))
                $fatal(1,"Copy address/parity/data wrong: %0d %h expected %0d %h",fa,fd,writes,writes^seed);
            writes=writes+1;
        end
    end
    initial begin
        if($value$plusargs("FAULT=%d",fault_arg)) begin end
        repeat(4) @(negedge clk);reset_n=1;
        request=1;repeat(100) @(negedge clk);
        if(busy||fw||ack) $fatal(1,"Copy started from a partial reset-time blank");
        request=0;
        for(frame=0;frame<4;frame=frame+1) begin
            seed=frame*16'h394b;
            for(i=0;i<32448;i=i+1) begin
                @(negedge clk);we=1;wa=i;wd=i^seed;
            end
            @(negedge clk);we=0;writes=0;cycles=0;
            request=~request;
            repeat(500) @(negedge clk);
            if(busy||fw) $fatal(1,"Late blank request started without a fresh blank edge");
            blank=0;repeat(20) @(negedge clk);
            blank=1;
            wait(ack==request);#1;
            if(fault_arg) begin
                if(!error) $fatal(1,"RAM read corruption not detected by frame CRC32");
                $display("PASS injected RAM bit corruption detected by frame CRC32");$finish;
            end
            if(writes!=32448||cycles>32451||error) $fatal(1,"Incomplete/late frame copy %0d in %0d cycles",writes,cycles);
            for(j=0;j<2028;j=j+1) begin
                @(negedge pixel);ra=j;x=(j%52)*2;y=(j/52)*2;
                e0=block_value(x,y);e1=block_value(x+1,y);
                e2=block_value(x,y+1);e3=block_value(x+1,y+1);
                @(posedge pixel);#1;
                if({p0,p1,p2,p3}!=={e0,e1,e2,e3}) $fatal(1,"Presented frame RAM mismatch at bank address %0d",j);
            end
            $display("PASS blank-copy frame=%0d pixels=%0d cycles=%0d all parity banks verified",frame,writes,cycles);
        end
        $finish;
    end
    initial begin #20000000;$fatal(1,"Presenter timeout");end
endmodule
