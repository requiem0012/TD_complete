`timescale 1ns/1ps
module media_osd_snapshot_tb;
 reg clk=0;always #20 clk=~clk;
 reg rst=0;reg [9:0] cx=0,cy=0,x=0,y=0;
 reg [23:0] raw;wire [23:0] adjusted,rgb;wire active;
 media_osd dut(clk,rst,cx,cy,x,y,4'd7,1'b1,1'b1,1'b1,1'b0,1'b1,1'b0,1'b0,1'b0,1'b0,raw,adjusted,active,rgb);
 integer f,i,j;reg [23:0] pixel;
 initial begin
  repeat(3)@(negedge clk);rst=1;repeat(4)@(negedge clk);
  cx=799;cy=524;@(negedge clk);cx=0;cy=0;
  dut.scroll_pos=640;
  f=$fopen("ui_osd_preview.ppm","wb");$fwrite(f,"P6\n640 480\n255\n");
  for(j=0;j<480;j=j+1)for(i=0;i<640;i=i+1)begin
   x=i;y=j;raw={i[9:2],j[8:1],8'h70};#1;pixel=active?rgb:adjusted;
   $fwrite(f,"%c%c%c",pixel[23:16],pixel[15:8],pixel[7:0]);
  end
  $fclose(f);$display("PASS rendered RTL OSD preview");$finish;
 end
endmodule
