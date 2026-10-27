`timescale 1ns/1ps
module EG_LOGIC_BUFG(input i,output o);assign o=i;endmodule
module native_memory_tb;
 reg clk=0;always #10 clk=~clk;
 reg pixel_clk=0;always #20 pixel_clk=~pixel_clk;
 reg rst_n=0,we=0,bank=0,front=0,slide_enable=0;
 reg [1:0] effect=0;
 reg [16:0] waddr=0;reg [15:0] din=0;
 reg [9:0] x=0,y=524,offset=0;
 wire word_ready,sector_ready,stored,initialized,error;wire [23:0] rgb;
 reg [15:0] a[0:76799],b[0:76799];
 reg [23:0] ga[0:307199],gb[0:307199];
 sdram_media dut(.clk(clk),.rst_n(rst_n),.pixel_clk(pixel_clk),.pixel_rst_n(rst_n),
  .we(we),.bank(bank),.waddr(waddr),.din(din),.x(x),.y(y),.slide_offset(offset),
  .front(front),.slide_enable(slide_enable),.effect(effect),.word_ready(word_ready),.sector_ready(sector_ready),
  .stored(stored),.initialized(initialized),.error(error),.rgb(rgb));
 integer fault=0,checks=0;
 task upload;
  input target;
  integer s,j,n;
  begin
   bank=target;
   for(s=0;s<300;s=s+1)begin
    @(negedge clk);while(!sector_ready)begin
     if(error)$fatal(1,"Upload error before sector %d",s);
     @(negedge clk);
    end
    for(j=0;j<256;j=j+1)begin
     n=s*256+j;
     if(!word_ready)$fatal(1,"FIFO overflow");
     we=1;waddr=n;din=target?b[n]:a[n];
     @(negedge clk);we=0;@(negedge clk);
    end
   end
   if(fault)begin
    dut.u_sip.u_sip.memory.Bank0[0]=dut.u_sip.u_sip.memory.Bank0[0]^32'd1;
    wait(error);
    if(stored)$fatal(1,"Bad frame was published");
   end else begin
    while(!stored)begin
     if(error)$fatal(1,"RAM CRC/upload error bank=%d count=%d",target,dut.u_upload.written);
     @(negedge clk);
    end
   end
  end
 endtask
 task raster;
  input f;input integer pan;
  integer yy,xx,m,index,fold,flight,cy,dy,left_edge,span,diag,shade,h,rank;
  integer cx,u,v,tilt,tp,du,sv,su,sdist,sdiag,sx;
  reg paper,shadow;
  reg selected;reg [23:0] expected;
  begin
   front=f;slide_enable=(pan!=0);offset=pan;
   for(yy=-3;yy<525;yy=yy+1)begin
    for(xx=0;xx<800;xx=xx+1)begin
     @(negedge pixel_clk);x=xx;y=(yy<0)?525+yy:yy;
     @(posedge pixel_clk);#1;
     if(yy>=0&&yy<480&&xx<640)begin
      m=xx;selected=f;shade=0;
      if(pan!=0)case(effect)
       1:begin
        fold=(pan<320)?pan:320;flight=(pan<320)?0:(pan-320)*2;
        cx=320+flight;cy=240-flight/2-flight/4;
        u=xx-cx;tilt=(fold<256)?fold:256;tp=u*tilt;
        v=yy-cy+(tp>>>9);dy=(v<0)?-v:v;
        left_edge=-320+fold/2;
        span=(pan<320)?640-fold:320-flight/4;diag=dy*fold/128;du=u-left_edge;
        paper=span>diag&&u>=left_edge&&du<span-diag&&!(fold>=256&&du<32&&dy<8);
        su=u-12;sv=v-22;sdist=su-left_edge;sdiag=((sv<0)?-sv:sv)*fold/128;
        shadow=fold>=128&&span>sdiag&&su>=left_edge&&sdist<span-sdiag&&
               !(fold>=256&&sdist<32&&((sv<0)?-sv:sv)<8);
        if(paper)begin
         sx=320+u+(tp>>>8);m=(sx<0)?0:(sx>639)?639:sx;
         if(fold>=80&&v< -4)m=639-m;
         if(fold>=80)shade=(v<0)?1:2;
         if(fold>=192&&v>0&&dy>(span>>3)&&du<(span>>1))shade=5;
         if(fold>=160&&dy<3)shade=3;
         if(fold>=192&&span-diag-du<3)shade=6;
        end else begin selected=~f;if(shadow)shade=4;end
       end
       2:begin
        h={xx[4],yy[3],xx[2],yy[5],xx[6],yy[1],xx[0],yy[0],xx[1],yy[2]};
        rank=(((h*405+137)%1024)*5)/8;
        if(rank<pan)selected=~f;
       end
       default:begin m=xx+pan;if(m>=640)begin m=m-640;selected=~f;end end
      endcase
      index=yy*640+m;expected=selected?gb[index]:ga[index];
      case(shade)
       1:expected={expected[23:16]-(expected[23:16]>>2)+8'd48,expected[15:8]-(expected[15:8]>>2)+8'd48,expected[7:0]-(expected[7:0]>>2)+8'd48};
       2:expected={(expected[23:16]>>1)+(expected[23:16]>>3),(expected[15:8]>>1)+(expected[15:8]>>3),(expected[7:0]>>1)+(expected[7:0]>>3)};
       3:expected=24'hf5f5f5;
       4:expected={expected[23:16]>>1,expected[15:8]>>1,expected[7:0]>>1};
       5:expected={(expected[23:16]>>2)+8'd168,(expected[15:8]>>2)+8'd168,(expected[7:0]>>2)+8'd168};
       6:expected={(expected[23:16]>>2)+8'd192,(expected[15:8]>>2)+8'd192,(expected[7:0]>>2)+8'd192};
      endcase
      if(rgb!==expected)$fatal(1,"Pixel f=%d pan=%d x=%d y=%d got=%h want=%h",f,pan,xx,yy,rgb,expected);
      checks=checks+1;
     end
     if(error)$fatal(1,"Memory/cache error at x=%d y=%d",xx,yy-1);
    end
   end
  end
 endtask
 initial begin
  $readmemh("native_a.hex",a);$readmemh("native_b.hex",b);
  $readmemh("native_ga.hex",ga);$readmemh("native_gb.hex",gb);
  fault=$test$plusargs("fault");#51 rst_n=1;wait(initialized);
  upload(0);
  if(fault)begin $display("PASS bad SDRAM payload never published (RAM CRC32)");$finish;end
  upload(1);raster(0,0);
  fork raster(1,0);upload(0);join
  raster(0,317);
  if($test$plusargs("effects"))begin
   effect=1;raster(0,160);raster(1,400);
   effect=2;raster(0,160);raster(1,480);
   $display("PASS plane/dissolve cached BC1 raster: 1228800 exact effect pixels, both banks, tint/address pipeline, no memory deadlines");
  end
  $display("PASS native SDRAM load+readback CRC, concurrent refill and 921600 exact BC1 pixels including push");
  $finish;
 end
 initial begin
  if($test$plusargs("effects"))#240000000;else #120000000;
  $fatal(1,"Timeout state=%d upload=%d level=%d",dut.u_mem.state,dut.u_upload.state,dut.u_upload.level);
 end
endmodule
