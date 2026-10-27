`timescale 1ns/1ps
module hd_photo_tb;
 reg clk=0;always #10 clk=~clk;
 reg rst_n=0,load=0,valid=0,done=0;
 reg [31:0] base=0;reg [7:0] data;
 wire req,ack,we,loaded,err;wire [31:0] addr,crc;
 wire [14:0] wa;wire [15:0] wd;
 sd_loader dut(clk,rst_n,1'b1,load,base,data,valid,done,req,addr,ack,we,wa,wd,loaded,crc,err);
 reg [7:0] photo[0:65535];
 integer frame=0,words=0,sectors=0,j,index,bad=0;reg [31:0] requested;
 always @(posedge clk)if(we)begin
  if(bad)$fatal(1,"Invalid header produced writes");
  index=512+words*2;
  if(wa!==words||wd!=={photo[index+1],photo[index]})$fatal(1,"HD photo byte/order/address");
  words=words+1;
 end
 initial begin
  $readmemh("hd_photo.hex",photo);
  if($value$plusargs("BAD=%d",bad))begin end
  if(bad)photo[8]=1;
  #100;rst_n=1;
  for(frame=0;frame<5;frame=frame+1)begin
   @(negedge clk);base=(frame%4)*128;load=1;
   wait(ack);@(negedge clk);load=0;
   if(bad)begin
    wait(err);repeat(10)@(negedge clk);
    if(loaded||words)$fatal(1,"Wrong old format acceptance");
    $display("PASS HD rejects wrong photo header before any RAM write");$finish;
   end
   wait(loaded);@(negedge clk);
   if(words!=32448||err)$fatal(1,"HD photo length/error");words=0;
  end
  if(sectors!=640)$fatal(1,"Wrong sector count %d",sectors);
  $display("PASS HD photos 1,2,3,4,1: 640 sectors / 162240 words, header skipped and tail discarded");$finish;
 end
 initial forever begin
  wait(req);requested=addr;repeat(5)@(negedge clk);
  for(j=0;j<512;j=j+1)begin
   @(negedge clk);valid=1;data=photo[(requested%128)*512+j];
  end
  @(negedge clk);valid=0;done=1;
  @(negedge clk);done=0;sectors=sectors+1;
 end
 initial begin #30000000;$fatal(1,"HD photo timeout");end
endmodule
