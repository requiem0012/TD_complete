`timescale 1ns/1ps
module hd_render_tb;
 reg wc=0,rc=0;always #10 wc=~wc;always #20 rc=~rc;
 reg reset_n=0,we=0,bank=0,write_bank=0;reg [14:0] wa=0;reg [15:0] wd=0;
 reg [9:0] tx=0,ty=0,offset=0;reg slide=0;
 wire [10:0] a0,a1,a2,a3;
 wire [63:0] p0,p1,p2,p3,q0,q1,q2,q3;
 wire [7:0] r,g,b;wire owner;
 reg [15:0] words[0:32447];reg [23:0] golden[0:307199],golden_b[0:307199];
 wire select_bank=slide?owner:bank;
 bc1_framebuffer a(wc,we&&!write_bank,wa,wd,rc,a0,a1,a2,a3,p0,p1,p2,p3,11'd0,,,,);
 bc1_framebuffer #(.USE_32K(1)) z(wc,we&&write_bank,wa,wd,rc,a0,a1,a2,a3,q0,q1,q2,q3,11'd0,,,,);
 vga_disp #(.ENABLE_SLIDE(1)) scale(rc,reset_n,tx,ty,
   select_bank?q0:p0,select_bank?q1:p1,select_bank?q2:p2,select_bank?q3:p3,a0,a1,a2,a3,r,g,b,offset,1'b0,slide,owner);
 integer backend,i,j,lx,ly,px,py,checked,wrapped;
 reg [23:0] current,previous;reg active;
 initial begin
  $readmemh("hd_words.hex",words);$readmemh("hd_pixels.hex",golden);
  $readmemh("hd_pixels_b.hex",golden_b);
  for(j=0;j<2;j=j+1)begin
   for(i=0;i<32448;i=i+1)begin @(negedge wc);write_bank=j;we=1;wa=i;wd=words[i]^(j?16'h55aa:0);end
  end
  @(negedge wc);we=0;
  for(backend=0;backend<3;backend=backend+1)begin
   reset_n=0;bank=(backend==1);slide=(backend==2);offset=slide?317:0;
   repeat(3)@(negedge rc);reset_n=1;active=0;checked=0;
   // Warm the complete RAM/decode/MAC pipeline with real blank coordinates.
   for(i=780;i<800;i=i+1)begin @(negedge rc);tx=i;ty=524;end
   for(i=0;i<420001;i=i+1)begin
    @(negedge rc);tx=i%800;ty=(i/800)%525;
    lx=(tx==799)?0:tx+1;ly=(tx==799)?((ty==524)?0:ty+1):ty;
    px=(lx<640)?lx:0;py=(ly<480)?ly:0;
    wrapped=slide&&(px+317>=640);
    if(slide)px=(px+317)%640;
    current=(bank||wrapped)?golden_b[py*640+px]:golden[py*640+px];
    @(posedge rc);#1;
    if(active)begin
     if({r,g,b}!==previous)$fatal(1,"HD renderer RAM=%d cycle=%d got=%h expected=%h",backend,i,{r,g,b},previous);
     checked=checked+1;
    end
    previous=current;active=(i<420000)&&(lx<640)&&(ly<480);
   end
   if(checked!=307200)$fatal(1,"wrong check count");
   $display("PASS HD renderer backend=%0d all 307200 pixels (BC1, RAM chunks, borders, bilinear, slide)",backend);
  end
  $finish;
 end
endmodule
