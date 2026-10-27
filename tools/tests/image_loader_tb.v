`timescale 1ns/1ps
module image_loader_tb;
    reg clk=0;always #10 clk=~clk;
    reg rst_n=0,load=0,valid=0,done=0;
    reg [31:0] base=0;
    reg [7:0] data;
    wire req,ack,we,loaded;
    wire [31:0] addr;
    wire [14:0] wa;
    wire [15:0] wd;
    sd_loader dut(clk,rst_n,1'b1,load,base,data,valid,done,req,addr,ack,we,wa,wd,loaded);
    reg [7:0] images[0:239999];
    integer frame=0,pixels=0,sectors=0,j,index,image;
    reg [31:0] requested;
    always @(posedge clk)if(we)begin
        index=(frame%4)*60000+pixels*2;
        if(wa!==pixels)$fatal(1,"Image pixel address");
        if(wd!=={images[index+1],images[index]})$fatal(1,"Image byte order/data");
        pixels=pixels+1;
    end
    initial begin
        $readmemh("images.hex",images);
        #100;rst_n=1;
        for(frame=0;frame<5;frame=frame+1)begin
            @(negedge clk);base=(frame%4)*128;load=1;
            wait(ack);@(negedge clk);load=0;
            wait(loaded);@(negedge clk);
            if(pixels!=30000)$fatal(1,"Image tail/length");pixels=0;
        end
        if(sectors!=590)$fatal(1,"Wrong sector count");
        $display("PASS image files 0,1,2,3,0: 590 sectors, 150000 RGB565 pixels and tail padding");$finish;
    end
    initial forever begin
        wait(req);requested=addr;image=requested/128;
        if(requested%128>=118)$fatal(1,"Image sector outside slot");
        repeat(5)@(negedge clk);
        for(j=0;j<512;j=j+1)begin
            @(negedge clk);valid=1;index=(requested%128)*512+j;
            data=(index<60000)?images[image*60000+index]:8'hbb;
        end
        @(negedge clk);valid=0;done=1;
        @(negedge clk);done=0;sectors=sectors+1;
    end
    initial begin #30000000;$fatal(1,"Image timeout");end
endmodule
