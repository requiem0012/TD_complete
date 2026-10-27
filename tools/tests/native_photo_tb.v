`timescale 1ns/1ps
module EG_LOGIC_BUFG(input i,output o);assign o=i;endmodule
module native_photo_tb;
 reg clk=0;always #10 clk=~clk;
 reg pixel_clk=0;always #20 pixel_clk=~pixel_clk;
 reg rst=0,n=0,p=0,blank=0;integer ticks=0;
 always @(negedge clk)begin ticks=ticks+1;blank=(ticks%200>=100);end
 wire nl,pl,load_req,load_ack,raw_done,loaded,valid,front,wb,event_out;
 wire [9:0] offset;wire [31:0] base,lba,expected_crc;
 wire read,fb_we;wire [16:0] fb_addr;wire [15:0] fb_data;
 reg [7:0] data=0;reg sd_valid=0,sd_end=0;
 wire fmt_error,mem_error,sector_ready,word_ready,stored,initialized;
 reg [9:0] x=0,y=524;
 wire [23:0] rgb;
 reg [7:0] file_data[0:1048575];
 integer fd,got,i,reads=0,writes=0,loads=0;
 reg [31:0] crc=32'hffffffff;
 assign loaded=raw_done&&stored&&!mem_error;
 photo_slide slide(.clk(clk),.rst_n(rst),.vblank(blank),.loaded(loaded),.next_press(n),.previous_press(p),
  .next_load(nl),.previous_load(pl),.offset(offset),.front(front),.valid(valid),.write_bank(wb),.auto_enable(1'b0));
 image_controller controller(.clk(clk),.rst_n(rst),.sd_init_done(initialized),.key_press(nl),.previous_press(pl),
  .load_ack(load_ack),.load_req(load_req),.base_sector(base),.switch_event(event_out));
 sd_loader loader(.clk(clk),.rst_n(rst),.sd_init_done(initialized),.load_req(load_req),.fb_ready(sector_ready),
  .base_sector(base),.sd_data(data),.sd_valid(sd_valid),.sd_read_end(sd_end),.sd_read(read),.sd_addr(lba),
  .load_ack(load_ack),.fb_we(fb_we),.fb_addr(fb_addr),.fb_data(fb_data),.load_done(raw_done),
  .expected_crc(expected_crc),.format_error(fmt_error));
 sdram_media memory(.clk(clk),.rst_n(rst),.pixel_clk(pixel_clk),.pixel_rst_n(rst),
  .we(fb_we),.bank(wb),.waddr(fb_addr),.din(fb_data),.x(x),.y(y),.slide_offset(offset),
  .front(front),.slide_enable(1'b1),.word_ready(word_ready),.sector_ready(sector_ready),.stored(stored),
  .initialized(initialized),.error(mem_error),.rgb(rgb));
 function [31:0] crc_byte;input [31:0] c;input [7:0] d;reg [31:0] v;integer k;
 begin v=c^d;for(k=0;k<8;k=k+1)v=v[0]?((v>>1)^32'hedb88320):(v>>1);crc_byte=v;end endfunction
 reg seen_valid=0,last_done=0;
 always @(posedge clk)if(rst)begin
  if(fmt_error||mem_error)$fatal(1,"Photo format/memory error");
  if(valid)seen_valid<=1;
  if(seen_valid&&!valid)$fatal(1,"Black gap while changing photos");
  if(load_ack)begin crc<=32'hffffffff;writes<=0;end
  if(fb_we)begin
   if(fb_addr!=writes)$fatal(1,"Photo address/order mismatch");
   writes<=writes+1;crc<=crc_byte(crc_byte(crc,fb_data[7:0]),fb_data[15:8]);
  end
  last_done<=loaded;
  if(loaded&&!last_done)begin
   if(writes!=76800||(~crc)!=expected_crc)$fatal(1,"Photo header/payload CRC mismatch");
   loads<=loads+1;
  end
 end
 initial begin
  fd=$fopen("../TF_NATIVE_4images.img","rb");if(!fd)$fatal(1,"Missing native photos");
  got=$fread(file_data,fd);$fclose(fd);if(got!=1048576)$fatal(1,"Photo fixture size");
  #51 rst=1;
  forever begin
   wait(read);
   if(lba>=1536)$fatal(1,"Photo LBA outside first three slots");
   reads=reads+1;repeat(12)@(negedge clk);
   for(i=0;i<512;i=i+1)begin @(negedge clk);data=file_data[lba*512+i];sd_valid=1;end
   @(negedge clk);sd_valid=0;sd_end=1;
   @(negedge clk);sd_end=0;
  end
 end
 task change;
  input previous;input [31:0] expected_base;input integer expected_loads;
  begin
   wait(slide.phase==0&&loaded);@(negedge clk);p=previous;n=!previous;
   @(negedge clk);p=0;n=0;
   wait(loads==expected_loads);wait(slide.phase==0);repeat(10)@(negedge clk);
   if(base!=expected_base||!valid||offset!=0)$fatal(1,"Photo direction/stride/push failure");
  end
 endtask
 initial begin
  wait(loads==1&&valid);change(0,512,2);change(1,0,3);change(1,1024,4);change(0,0,5);
  if(reads!=1505)$fatal(1,"Photo sector count %d",reads);
  $display("PASS native photos: 5 frames, 1505 sectors, exact bytes/CRC, 512-sector slots, previous/wrap and no black gap");
  $finish;
 end
 initial begin #100000000;$fatal(1,"Photo timeout loads=%d phase=%d state=%d",loads,slide.phase,loader.state);end
endmodule
