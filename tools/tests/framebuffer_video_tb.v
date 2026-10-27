`timescale 1ns/1ps
// Public synchronous dual-port behavior model for verification only.
// Vendor 32K primitive electrical timing still needs board verification.
module EG_LOGIC_BRAM #(
    parameter DATA_WIDTH_A=16,DATA_WIDTH_B=16,ADDR_WIDTH_A=11,ADDR_WIDTH_B=11,
    DATA_DEPTH_A=2048,DATA_DEPTH_B=2048,MODE="DP",REGMODE_A="NOREG",REGMODE_B="NOREG",IMPLEMENT="32K"
)(input [DATA_WIDTH_A-1:0] dia,input [DATA_WIDTH_B-1:0] dib,
   input [ADDR_WIDTH_A-1:0] addra,input [ADDR_WIDTH_B-1:0] addrb,
   input cea,ceb,ocea,oceb,clka,clkb,wea,web,rsta,rstb,bea,beb,
   output reg [DATA_WIDTH_A-1:0] doa,output reg [DATA_WIDTH_B-1:0] dob);
    reg [15:0] m[0:2047];
    always @(posedge clka)if(cea)begin if(wea)m[addra]<=dia;doa<=m[addra];end
    always @(posedge clkb)if(ceb)begin if(web)m[addrb]<=dib;dob<=m[addrb];end
endmodule

module framebuffer_video_tb;
    reg wc=0,rc=0;always #10 wc=~wc;always #20 rc=~rc;
    reg we=0;reg [14:0] wa;reg [15:0] wd;
    reg [12:0] a0,a1,a2,a3;
    wire [15:0] qa0,qa1,qa2,qa3,qb0,qb1,qb2,qb3;
    wire [15:0] aux0,aux1,aux2,aux3;
    framebuffer a(wc,we,wa,wd,rc,a0,a1,a2,a3,qa0,qa1,qa2,qa3,13'd0,,,,);
    framebuffer #(.USE_32K(1),.AUX_READ(1)) b(wc,we,wa,wd,rc,a0,a1,a2,a3,qb0,qb1,qb2,qb3,a0,aux0,aux1,aux2,aux3);
    integer f,i,j,x,y,seed;
    reg [15:0] e0,e1,e2,e3;
    initial begin
        for(f=0;f<2;f=f+1) begin
            seed=f*16'h55aa;
            for(i=0;i<30000;i=i+1)begin
                @(negedge wc);we=1;wa=i;wd=i^seed;
            end
            @(negedge wc);we=0;
            for(j=0;j<7500;j=j+1)begin
                @(negedge rc);a0=j;a1=j;a2=j;a3=j;
                x=(j%100)*2;y=(j/100)*2;
                e0=(y*200+x)^seed;e1=(y*200+x+1)^seed;
                e2=((y+1)*200+x)^seed;e3=((y+1)*200+x+1)^seed;
                @(posedge rc);#1;
                if({qa0,qa1,qa2,qa3}!=={e0,e1,e2,e3})$fatal(1,"9K parity mismatch");
                if({qb0,qb1,qb2,qb3}!=={e0,e1,e2,e3})$fatal(1,"32K latency/parity mismatch at %d",j);
                if({aux0,aux1,aux2,aux3}!=={e0,e1,e2,e3})$fatal(1,"32K independent 50 MHz A-port mismatch at %d",j);
            end
        end
        $display("PASS framebuffer 60000 pixels, four parity banks and all 32K chunk boundaries");$finish;
    end
endmodule
