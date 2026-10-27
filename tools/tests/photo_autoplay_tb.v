`timescale 1ns/1ps
module photo_autoplay_tb;
 reg clk=0;always #10 clk=~clk;
 reg rst=0,blank=0,loaded=0,n=0,p=0,ack=0,enable=0;
 wire nl,pl,req,event_out,front,valid,write_bank;
 wire [9:0] offset;wire [31:0] base;
 localparam INTERVAL=1000;
 photo_slide #(.AUTO_INTERVAL_CYCLES(INTERVAL)) dut(clk,rst,blank,loaded,n,p,nl,pl,offset,front,valid,write_bank,enable);
 image_controller ctrl(.clk(clk),.rst_n(rst),.sd_init_done(1'b1),.key_press(nl),
 .previous_press(pl),.load_ack(ack),.load_req(req),.base_sector(base),.switch_event(event_out));
 integer ticks=0,nav=0,delay_left=0,latency=30,i,saved;
 reg real_enable=0;
 wire real_nl;
 photo_slide real_default(.clk(clk),.rst_n(rst),.vblank(blank),.loaded(1'b1),
   .next_press(1'b0),.previous_press(1'b0),.next_load(real_nl),.auto_enable(real_enable));
 reg reading=0;time last_nav=0,now_nav;
 always @(negedge clk)begin ticks=ticks+1;blank=(ticks%8>=4);end
 always @(posedge clk)begin
  if(!rst)begin loaded<=0;ack<=0;reading<=0;delay_left<=0;end
  else begin
   ack<=0;
   if(!reading&&req)begin ack<=1;loaded<=0;reading<=1;delay_left<=latency;end
   else if(reading)begin
    if(delay_left==0)begin loaded<=1;reading<=0;end
    else delay_left<=delay_left-1;
   end
   if(nl||pl)nav=nav+1;
   if(valid&&reading&&write_bank==front)$fatal(1,"Loading active bank");
  end
 end
 task get_nav;
 input integer expected_previous,expected_base,check_interval;
 begin
  wait(nl||pl);#1;
  now_nav=$time;
  if(pl!==expected_previous||nl===pl)$fatal(1,"Wrong auto/manual direction");
  if(check_interval&&now_nav-last_nav!=INTERVAL*20)$fatal(1,"Interval got %0t expected %0d cycles",now_nav-last_nav,INTERVAL);
  last_nav=now_nav;
  repeat(2)@(negedge clk);
  if(base!==expected_base)$fatal(1,"Wrong image/wrap base %d expected %d",base,expected_base);
  wait(!nl&&!pl);
 end
 endtask
 initial begin
  #100;rst=1;wait(valid&&dut.phase==0);
  repeat(INTERVAL*2)@(negedge clk);
  if(nav||offset)$fatal(1,"Auto ran with SW4 low");
  enable=1;
  get_nav(0,128,0);get_nav(0,256,1);get_nav(0,384,1);get_nav(0,0,1);
  // Disabling must not abort a preload or leave a half-slide on screen.
  enable=0;wait(dut.phase==0);saved=nav;
  repeat(INTERVAL*2)@(negedge clk);
  if(nav!=saved||offset||!valid)$fatal(1,"Disable did not finish/stop cleanly");
  // Manual PREVIOUS wins on the exact automatic deadline.
  enable=1;wait(dut.auto_count==INTERVAL-1);
  @(negedge clk);p=1;
  get_nav(1,384,0);p=0;
  get_nav(0,0,1);
  // A slow card must defer one deadline, never issue a request while busy.
  wait(dut.phase==0);
  latency=INTERVAL*2;
  get_nav(0,128,1);
  wait(dut.auto_count==INTERVAL-1);saved=nav;
  repeat(50)@(negedge clk);
  if(nav!=saved||dut.phase==0||!valid||offset)$fatal(1,"Slow card queued or blanked");
  wait(dut.phase==3);wait(dut.phase==0);
  get_nav(0,256,0);
  enable=0;wait(dut.phase==0);
  // Leaving photo mode resets the counter; returning starts a fresh interval.
  @(negedge clk);rst=0;repeat(4)@(negedge clk);
  if(dut.auto_count||valid||nl||pl)$fatal(1,"Photo reset did not cancel auto");
  latency=30;rst=1;enable=1;wait(valid);
  repeat(INTERVAL-2)@(negedge clk);
  if(nl||pl||dut.phase!=0)$fatal(1,"Returned photo mode switched too early");
  get_nav(0,128,0);
  // Check the unmodified production default near its deadline, without
  // accelerating the 50 MHz constant or simulating 150 million idle cycles.
  @(negedge clk);real_enable=1;real_default.auto_count=28'd149999990;
  for(i=0;i<9;i=i+1)begin
   @(posedge clk);#1;if(real_nl)$fatal(1,"Production 3-second timer fired early");
  end
  @(posedge clk);#1;if(!real_nl)$fatal(1,"Production 150000000-cycle deadline failed");
  $display("PASS SW4 photo auto: exact intervals, 1->2->3->4->1, manual priority, disable, slow card and mode reset");
  $finish;
 end
 initial begin #2000000;$fatal(1,"Autoplay timeout phase=%d count=%d nav=%d",dut.phase,dut.auto_count,nav);end
endmodule
