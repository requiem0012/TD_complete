`timescale 1ns/1ps
module media_osd_tb;
 reg clk=0;always #20 clk=~clk;
 reg rst=0;reg [9:0] cx=0,cy=0,x=0,y=0;
 reg [3:0] gray=6;
 reg settings=0,loop_en=0,video=0,paused=0,ready=1,fmt=0,copy=0,under=0,retry=0;
 reg [23:0] raw=0;
 wire [23:0] adjusted,rgb;wire active;
 media_osd dut(clk,rst,cx,cy,x,y,gray,settings,loop_en,video,paused,ready,fmt,copy,under,retry,raw,adjusted,active,rgb);
 integer level,v,expected,checked=0,i,j,k,pixels=0;
 reg [4:0] rowbits;
 reg [23:0] expected_color;
 reg [34:0] glyph_value;
 task frame;
 begin
  cx=0;cy=0;repeat(4)@(negedge clk);
  cx=799;cy=524;@(negedge clk);cx=0;cy=0;
 end endtask
 task word_check;
 input [191:0] word;input integer yy;input [23:0] color;
 reg [7:0] ch;reg [34:0] font;reg ink;
 integer px,py,c,r,col;
 begin
  for(py=0;py<14;py=py+1)for(px=0;px<288;px=px+1)begin
   x=px+8;y=py+yy;#1;c=px/12;col=(px%12)/2;r=py/2;
   ch=word[191-c*8-:8];font=dut.glyph(ch);
   ink=(col<5)?font[34-r*5-col]:0;
   if(!active||rgb!==(ink?color:24'h101010))$fatal(1,"OSD glyph/border %d %d",x,y);
   pixels=pixels+1;
  end
 end endtask
 initial begin
  repeat(3)@(negedge clk);rst=1;frame();
  // Exhaust all values and all nine brightness levels, including clamps.
  for(level=0;level<=8;level=level+1)begin
   gray=level^(level>>1);frame();
   if(dut.level_pix!==level)$fatal(1,"Gray/frame brightness mismatch");
   for(v=0;v<256;v=v+1)begin
    raw={v[7:0],v[7:0],v[7:0]};#1;
    expected=v+(level-4)*16;if(expected<0)expected=0;if(expected>255)expected=255;
    if(v==0)expected=0;
    if(adjusted!=={expected[7:0],expected[7:0],expected[7:0]})$fatal(1,"Brightness clamp level=%d value=%d got=%h",level,v,adjusted);
    checked=checked+1;
   end
  end
  gray=6;frame();raw=24'h1256ab;#1;if(adjusted!==raw)$fatal(1,"Neutral not bit-exact");
  x=0;y=0;#1;if(active)$fatal(1,"OSD overlaps corner CRC");
  x=40;y=40;#1;if(active)$fatal(1,"OSD overlaps timestamp");
  loop_en=0;video=0;settings=0;frame();word_check("PHOTO MANUAL            ",64,24'hffffff);
  loop_en=1;frame();word_check("PHOTO AUTO              ",64,24'hffffff);
  video=1;frame();word_check("VIDEO PLAY LOOP         ",64,24'hffffff);
  paused=1;loop_en=0;frame();word_check("VIDEO PAUSE ONCE        ",64,24'hffffff);
  fmt=1;frame();word_check("MEDIA FORMAT ERROR      ",124,24'hff5555);
  copy=1;frame();word_check("FRAME CHECK ERROR       ",124,24'hff5555);
  fmt=0;copy=0;under=1;frame();word_check("AUDIO UNDERRUN HISTORY  ",124,24'hffcc00);
  under=0;retry=1;frame();word_check("SD RETRY HISTORY        ",124,24'hffcc00);
  settings=1;gray=7;frame(); // Gray 7 is level 5, +1.
  word_check("BRIGHTNESS +1           ",84,24'hffcc00);
  settings=0;frame();if(dut.popup_frames!=180)$fatal(1,"Exit popup deadline");
  repeat(180)frame();if(dut.popup_frames)$fatal(1,"Popup failed to expire");
  // Known F glyph reference and all visible ticker pixels at 3 positions.
  glyph_value=35'b11111_10000_10000_11110_10000_10000_10000;
  if(dut.glyph(8'h46)!==glyph_value)$fatal(1,"F glyph bitmap wrong");
  for(k=0;k<3;k=k+1)begin
   @(negedge clk);dut.scroll_pos=(k==0)?1:(k==1)?640:1407;
   for(j=448;j<480;j=j+1)for(i=0;i<640;i=i+1)begin
    x=i;y=j;#1;
    if(!active)$fatal(1,"Ticker strip gap");
    if(rgb!==24'h101010&&rgb!==24'h66ddff)$fatal(1,"Ticker color");
   end
  end
  @(negedge clk);dut.scroll_pos=1407;frame();if(dut.scroll_pos!=0)$fatal(1,"Ticker wrap");
  $display("PASS OSD: %d brightness combinations, %d text pixels, status/faults, popup, black bars, ticker wrap",checked,pixels);
  $finish;
 end
 initial begin #1000000;$fatal(1,"OSD timeout");end
endmodule
