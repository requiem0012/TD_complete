`timescale 1ns/1ps
module ui_controls_tb;
 reg clk=0;always #10 clk=~clk;
 reg rst=0,sw3=0,n=0,p=0;
 wire settings,nn,np;wire [3:0] gray;
 ui_controls #(.DEBOUNCE_CYCLES(8)) dut(clk,rst,sw3,n,p,settings,gray,nn,np);
 integer i;
 task press;input previous;
 begin @(negedge clk);n=!previous;p=previous;@(negedge clk);n=0;p=0;end endtask
 initial begin
  repeat(3)@(negedge clk);rst=1;
  if(gray!==6)$fatal(1,"Default brightness");
  n=1;#1;if(!nn||np)$fatal(1,"Normal nav blocked");n=0;
  sw3=1;repeat(4)@(negedge clk);sw3=0;repeat(12)@(negedge clk);
  if(settings)$fatal(1,"SW3 bounce accepted");
  sw3=1;repeat(12)@(negedge clk);if(!settings)$fatal(1,"SW3 stable not accepted");
  n=1;#1;if(nn||np)$fatal(1,"Settings leaked nav");n=0;
  for(i=0;i<12;i=i+1)press(0);
  if(dut.level!=8||gray!=12)$fatal(1,"Brightness high clamp");
  for(i=0;i<20;i=i+1)press(1);
  if(dut.level!=0||gray!=0)$fatal(1,"Brightness low clamp");
  sw3=0;repeat(12)@(negedge clk);if(settings)$fatal(1,"SW3 exit");
  p=1;#1;if(!np||nn)$fatal(1,"Previous not restored");p=0;
  if(dut.level!=0)$fatal(1,"Brightness lost on exit");
  rst=0;#1;if(gray!=6||settings)$fatal(1,"Reset default");
  $display("PASS UI controls: debounce, nav isolation/restoration, +/-4 saturation and reset");$finish;
 end
endmodule
