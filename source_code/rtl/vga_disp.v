// 416x312 BC1, eight-bit subpixel bilinear upscale to 640x480.
// Registered horizontal blends split decode/MAC from vertical MAC/OSD.
// Two-pixel lookahead compensates the extra register: external RGB timing
// remains identical. slide_bank must stay aligned to the RAM/decode stage.
module vga_disp #(parameter ENABLE_SLIDE=0)(
 input wire clk,reset_n,input wire [9:0] timing_x,timing_y,
 input wire [63:0] fb_data00,fb_data01,fb_data10,fb_data11,
 output reg [10:0] fb_addr00,fb_addr01,fb_addr10,fb_addr11,
 output wire [7:0] VGA_R,VGA_G,VGA_B,
 input wire [9:0] slide_offset,input wire slide_front,slide_enable,
 output reg slide_bank
);
 wire [9:0] look_x=(timing_x>=798)?timing_x-10'd798:timing_x+10'd2;
 wire [9:0] look_y=(timing_x>=798)?((timing_y==524)?10'd0:timing_y+1'b1):timing_y;
 wire [9:0] raster_x=(look_x<640)?look_x:10'd0;
 wire [10:0] shifted={1'b0,raster_x}+{1'b0,slide_offset};
 wire wrap_x=shifted>=640;
 wire [10:0] mapped=wrap_x?shifted-11'd640:shifted;
 wire use_slide=ENABLE_SLIDE&&slide_enable;
 wire [9:0] px=use_slide?mapped[9:0]:raster_x;
 wire [9:0] py=(look_y<480)?look_y:10'd0;
 wire requested_bank=use_slide?(slide_front^wrap_x):1'b0;
 // 13/20 * 256 = 832/5. Floor only once, retaining eight fraction bits.
 wire [17:0] x_fp=(px*20'd832)/5;
 wire [17:0] y_fp=(py*20'd832)/5;
 wire [8:0] sx=x_fp[16:8],sy=y_fp[16:8];
 wire [8:0] sx1=(sx==415)?sx:sx+1'b1;
 wire [8:0] sy1=(sy==311)?sy:sy+1'b1;
 function [10:0] ba;input [8:0] x,y;
 begin ba=(y>>3)*52+(x>>3);end endfunction
 wire [10:0] a00=ba(sx,sy),a01=ba(sx1,sy),a10=ba(sx,sy1),a11=ba(sx1,sy1);
 reg [8:0] x0a,x1a,y0a,y1a,x0b,x1b,y0b,y1b;
 reg [7:0] fxa,fya,frac_x_r2,frac_y_r2;
 reg banka;
 always @(posedge clk or negedge reset_n) begin
  if(!reset_n)begin
   fb_addr00<=0;fb_addr01<=0;fb_addr10<=0;fb_addr11<=0;
   x0a<=0;x1a<=0;y0a<=0;y1a<=0;x0b<=0;x1b<=0;y0b<=0;y1b<=0;
   fxa<=0;fya<=0;frac_x_r2<=0;frac_y_r2<=0;banka<=0;slide_bank<=0;
  end else begin
   case({sy[2],sx[2]})
    0:begin fb_addr00<=a00;fb_addr01<=a01;fb_addr10<=a10;fb_addr11<=a11;end
    1:begin fb_addr00<=a01;fb_addr01<=a00;fb_addr10<=a11;fb_addr11<=a10;end
    2:begin fb_addr00<=a10;fb_addr01<=a11;fb_addr10<=a00;fb_addr11<=a01;end
    3:begin fb_addr00<=a11;fb_addr01<=a10;fb_addr10<=a01;fb_addr11<=a00;end
   endcase
   x0a<=sx;x1a<=sx1;y0a<=sy;y1a<=sy1;fxa<=x_fp[7:0];fya<=y_fp[7:0];banka<=requested_bank;
   x0b<=x0a;x1b<=x1a;y0b<=y0a;y1b<=y1a;frac_x_r2<=fxa;frac_y_r2<=fya;slide_bank<=banka;
  end
 end
 function [7:0] channel;
 input [7:0] a,b;input [1:0] i;input four;
 reg [9:0] v;
 begin
  case(i)
   0:channel=a;
   1:channel=b;
   2:begin v=four?({2'b0,a}*2+{2'b0,b}):({2'b0,a}+{2'b0,b});channel=four?(v/3):(v>>1);end
   3:begin v={2'b0,a}+{2'b0,b}*2;channel=four?(v/3):8'd0;end
  endcase
 end endfunction
 function [23:0] pixel;
 input [63:0] d00,d01,d10,d11;input [8:0] x,y;
 reg [63:0] d;reg [15:0] c0,c1;reg [1:0] idx;reg four;
 begin
  case({y[2],x[2]})0:d=d00;1:d=d01;2:d=d10;3:d=d11;endcase
  c0=d[15:0];c1=d[31:16];idx=(d>>(32+({y[1:0],x[1:0]}*2)));four=c0>c1;
  pixel={channel({c0[15:11],c0[15:13]},{c1[15:11],c1[15:13]},idx,four),
         channel({c0[10:5],c0[10:9]},{c1[10:5],c1[10:9]},idx,four),
         channel({c0[4:0],c0[4:2]},{c1[4:0],c1[4:2]},idx,four)};
 end endfunction
 wire [23:0] p00=pixel(fb_data00,fb_data01,fb_data10,fb_data11,x0b,y0b);
 wire [23:0] p10=pixel(fb_data00,fb_data01,fb_data10,fb_data11,x1b,y0b);
 wire [23:0] p01=pixel(fb_data00,fb_data01,fb_data10,fb_data11,x0b,y1b);
 wire [23:0] p11=pixel(fb_data00,fb_data01,fb_data10,fb_data11,x1b,y1b);
    function [15:0] lerp8;
        input [7:0] a;
        input [7:0] b;
        input [7:0] f;
        reg signed [8:0]  delta;
        reg signed [17:0] value;
        begin
            delta = $signed({1'b0, b}) - $signed({1'b0, a});
            value = $signed({1'b0, a, 8'b00000000}) +
                    delta * $signed({1'b0, f});
            lerp8 = value[15:0];
        end
    endfunction

    function [7:0] lerp16;
        input [15:0] a;
        input [15:0] b;
        input [7:0]  f;
        reg signed [16:0] delta;
        reg signed [25:0] value;
        begin
            delta = $signed({1'b0, b}) - $signed({1'b0, a});
            value = $signed({1'b0, a, 8'b00000000}) +
                    delta * $signed({1'b0, f}) + 26'sd32768;
            lerp16 = value[23:16];
        end
    endfunction

    reg [15:0] top_r,top_g,top_b,bot_r,bot_g,bot_b;
    reg [7:0] frac_y_r3;
    always @(posedge clk or negedge reset_n)begin
      if(!reset_n)begin top_r<=0;top_g<=0;top_b<=0;bot_r<=0;bot_g<=0;bot_b<=0;frac_y_r3<=0;end
      else begin
        top_r<=lerp8(p00[23:16],p10[23:16],frac_x_r2);
        top_g<=lerp8(p00[15:8],p10[15:8],frac_x_r2);
        top_b<=lerp8(p00[7:0],p10[7:0],frac_x_r2);
        bot_r<=lerp8(p01[23:16],p11[23:16],frac_x_r2);
        bot_g<=lerp8(p01[15:8],p11[15:8],frac_x_r2);
        bot_b<=lerp8(p01[7:0],p11[7:0],frac_x_r2);
        frac_y_r3<=frac_y_r2;
      end
    end
    assign VGA_R=lerp16(top_r,bot_r,frac_y_r3);
    assign VGA_G=lerp16(top_g,bot_g,frac_y_r3);
    assign VGA_B=lerp16(top_b,bot_b,frac_y_r3);
endmodule
