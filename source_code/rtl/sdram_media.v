// Native 640x480 BC1 frames: 153600 bytes / 76800 halfwords.
// Each SDRAM frame occupies a 65536-word (256 KiB) slot.
// The upload FIFO holds two SD sectors. Sector requests start only when empty.
module sdram_upload(
 input wire clk,rst_n,we,bank,input wire [16:0] waddr,input wire [15:0] din,
 output wire word_ready,sector_ready,output reg stored,error,
 output wire req,write,output wire [20:0] addr,output wire [255:0] wdata,
 input wire ready,done,input wire [255:0] rdata
);
 reg [255:0] fifo[0:31];reg [255:0] packbuf,q;reg q_valid;
 reg [4:0] wp,rp;reg [5:0] level;reg [3:0] pack_index;
 reg frame_bank,received;reg [16:0] expected_address;
 reg [12:0] written,verified;
 reg [31:0] source_crc,ram_crc,reference_crc;
 reg [255:0] reply;reg [2:0] check_index;
 reg [2:0] state;
 localparam IDLE=0,WRITE_WAIT=1,READ_ISSUE=2,READ_WAIT=3,CHECK=4;
 wire accept=we&&word_ready;
 wire push=accept&&(pack_index==15);
 wire pop=(state==IDLE)&&(level!=0)&&q_valid&&ready;
 assign word_ready=(level<31)&&!received&&!error;
 assign sector_ready=(level==0)&&(pack_index==0)&&(state==IDLE)&&!received&&!error;
 assign req=!error&&((state==IDLE&&level!=0&&q_valid)||(state==READ_ISSUE));
 assign write=(state==IDLE);
 assign addr={4'd0,frame_bank,16'd0}+((state==IDLE)?{5'd0,written,3'd0}:{5'd0,verified,3'd0});
 assign wdata=q;
 function [31:0] crc_byte;input [31:0] c;input [7:0] d;reg [31:0] v;integer k;
 begin v=c^d;for(k=0;k<8;k=k+1)v=v[0]?((v>>1)^32'hedb88320):(v>>1);crc_byte=v;end endfunction
 function [31:0] crc_word;input [31:0] c,d;
 begin crc_word=crc_byte(crc_byte(crc_byte(crc_byte(c,d[7:0]),d[15:8]),d[23:16]),d[31:24]);end endfunction
 wire [31:0] input_crc=crc_byte(crc_byte(waddr==0?32'hffffffff:source_crc,din[7:0]),din[15:8]);
 wire [31:0] next_crc=crc_word(ram_crc,reply[check_index*32+:32]);
 always @(posedge clk)begin
  q<=fifo[rp];if(push)fifo[wp]<={din,packbuf[239:0]};
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   packbuf<=0;wp<=0;rp<=0;level<=0;pack_index<=0;frame_bank<=0;received<=0;q_valid<=0;
   expected_address<=0;written<=0;verified<=0;source_crc<=32'hffffffff;ram_crc<=32'hffffffff;
   reference_crc<=0;reply<=0;check_index<=0;state<=IDLE;stored<=0;error<=0;
  end else begin
   q_valid<=(level!=0);
   case({push,pop})2'b10:level<=level+1'b1;2'b01:level<=level-1'b1;default:begin end endcase
   if(we&&!word_ready)error<=1;
   if(accept)begin
    if(waddr==0)begin
     if((level!=0)||(state!=IDLE)||(pack_index!=0))error<=1;
     frame_bank<=bank;stored<=0;written<=0;expected_address<=1;
    end else begin
     if((waddr!=expected_address)||(bank!=frame_bank))error<=1;
     expected_address<=expected_address+1'b1;
    end
    packbuf[pack_index*16+:16]<=din;pack_index<=pack_index+1'b1;
    source_crc<=input_crc;
    if(push)wp<=wp+1'b1;
    if(waddr==76799)begin received<=1;reference_crc<=input_crc;end
   end
   case(state)
    IDLE:if(pop)begin rp<=rp+1'b1;state<=WRITE_WAIT;end
     else if(received&&(level==0))begin
      if(written!=4800||pack_index!=0)error<=1;
      verified<=0;ram_crc<=32'hffffffff;state<=READ_ISSUE;
     end
    WRITE_WAIT:if(done)begin written<=written+1'b1;state<=IDLE;end
    READ_ISSUE:if(ready&&!error)state<=READ_WAIT;
    READ_WAIT:if(done)begin reply<=rdata;check_index<=0;state<=CHECK;end
    CHECK:begin
     ram_crc<=next_crc;
     if(check_index==7)begin
      if(verified==4799)begin
       if(next_crc!=reference_crc)error<=1;
       else stored<=1;
       received<=0;expected_address<=0;state<=IDLE;
      end else begin verified<=verified+1'b1;state<=READ_ISSUE;end
     end else check_index<=check_index+1'b1;
    end
    default:state<=IDLE;
   endcase
  end
 end
endmodule

// Block-row caches: two 4-line rows for EACH frame, 5120 bytes total.
// Display reads have priority, bounded to 80 bursts per four raster lines.
module sdram_bc1_raster(
 input wire clk,rst_n,pixel_clk,pixel_rst_n,enable,
 input wire [9:0] x,y,slide_offset,input wire front,slide_enable,
 input wire [1:0] effect,
 output wire [23:0] rgb,output reg deadline_error,
 output wire req,output wire [20:0] addr,
 input wire ready,done,input wire [255:0] rdata
);
 reg [31:0] endpoint_a[0:319],index_a[0:319],endpoint_b[0:319],index_b[0:319];
 reg request_toggle,ack_toggle;reg [6:0] requested_row;
 reg [1:0] request_sync,ack_sync,enable_sync;
 reg [6:0] row,even_tag,odd_tag,even_meta,even_sync,odd_meta,odd_sync;
 reg frame;reg [5:0] burst;reg [2:0] copy_index,state;reg [255:0] reply;
 localparam IDLE=0,ISSUE=1,WAIT_DATA=2,COPY=3;
 wire [8:0] cache_word=(row[0]?9'd160:9'd0)+{1'b0,burst,2'b0}+{7'd0,copy_index[2:1]};
 wire [9:0] mapped_x;
 wire selected;
 wire [2:0] fold_shade;
 photo_transition_map u_effect(.x(x),.y(y),.progress(slide_offset),
  .effect(effect),.enable(slide_enable),.front(front),
  .mapped_x(mapped_x),.selected(selected),.shade(fold_shade));
 wire [8:0] cache_read=(y[2]?9'd160:9'd0)+((mapped_x<640)?{1'b0,mapped_x[9:2]}:9'd0);
 reg [31:0] ep_a,idx_a,ep_b,idx_b;reg [1:0] xi,yi;reg bank_d,visible,armed;
 reg [2:0] shade_d;
 wire [31:0] ep=bank_d?ep_b:ep_a,indices=bank_d?idx_b:idx_a;
 wire [1:0] choice=indices[({yi,xi}*2)+:2];
 function [7:0] channel;input [7:0] a,b;input [1:0] i;input four;reg [9:0] v;
 begin case(i)
  0:channel=a;1:channel=b;
  2:begin v=four?({2'b0,a}*2+{2'b0,b}):({2'b0,a}+{2'b0,b});channel=four?(v/3):(v>>1);end
  3:begin v={2'b0,a}+{2'b0,b}*2;channel=four?(v/3):8'd0;end
 endcase end endfunction
 wire [15:0] c0=ep[15:0],c1=ep[31:16];wire four=c0>c1;
 wire [23:0] color={
  channel({c0[15:11],c0[15:13]},{c1[15:11],c1[15:13]},choice,four),
  channel({c0[10:5],c0[10:9]},{c1[10:5],c1[10:9]},choice,four),
  channel({c0[4:0],c0[4:2]},{c1[4:0],c1[4:2]},choice,four)};
 function [7:0] paper_tint;input [7:0] c;input [2:0] s;
 begin case(s)
  1:paper_tint=c-(c>>2)+8'd48;
  2:paper_tint=(c>>1)+(c>>3);
  3:paper_tint=8'd245;
  4:paper_tint=c>>1;
  5:paper_tint=(c>>2)+8'd168;
  6:paper_tint=(c>>2)+8'd192;
  default:paper_tint=c;
 endcase end endfunction
 assign rgb=visible?{paper_tint(color[23:16],shade_d),
  paper_tint(color[15:8],shade_d),paper_tint(color[7:0],shade_d)}:24'd0;
 assign req=state==ISSUE;
 assign addr={4'd0,frame,16'd0}+({14'd0,row}*21'd320)+{12'd0,burst,3'b0};
 always @(posedge clk)if(state==COPY)begin
  if(!frame)begin
   if(copy_index[0])index_a[cache_word]<=reply[copy_index*32+:32];
   else endpoint_a[cache_word]<=reply[copy_index*32+:32];
  end else begin
   if(copy_index[0])index_b[cache_word]<=reply[copy_index*32+:32];
   else endpoint_b[cache_word]<=reply[copy_index*32+:32];
  end
 end
 always @(posedge pixel_clk)begin
  ep_a<=endpoint_a[cache_read];idx_a<=index_a[cache_read];
  ep_b<=endpoint_b[cache_read];idx_b<=index_b[cache_read];
 end
 always @(posedge pixel_clk or negedge pixel_rst_n)begin
  if(!pixel_rst_n)begin
   request_toggle<=0;requested_row<=0;ack_sync<=0;enable_sync<=0;
   even_meta<=127;even_sync<=127;odd_meta<=127;odd_sync<=127;
   xi<=0;yi<=0;bank_d<=0;visible<=0;deadline_error<=0;armed<=0;shade_d<=0;
  end else begin
   ack_sync<={ack_sync[0],ack_toggle};enable_sync<={enable_sync[0],enable};
   even_meta<=even_tag;even_sync<=even_meta;odd_meta<=odd_tag;odd_sync<=odd_meta;
   xi<=mapped_x[1:0];yi<=y[1:0];bank_d<=selected;
   shade_d<=fold_shade;
   visible<=enable_sync[1]&&(x<640)&&(y<480)&&
    (y[2]?(odd_sync==y[8:2]):(even_sync==y[8:2]));
   if((y>=480)&&(even_sync==0))armed<=1;
   if(enable_sync[1]&&(((x==0)&&(y<476)&&(y[1:0]==0))||((x==8)&&(y==522))))begin
    if(ack_sync[1]==request_toggle)begin
     requested_row<=(y==522)?7'd0:y[8:2]+1'b1;request_toggle<=~request_toggle;
    end else deadline_error<=1;
   end
   if(enable_sync[1]&&armed&&(x==1)&&(y<480)&&
    !(y[2]?(odd_sync==y[8:2]):(even_sync==y[8:2])))deadline_error<=1;
  end
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;request_sync<=0;ack_toggle<=0;row<=0;frame<=0;
   burst<=0;copy_index<=0;reply<=0;even_tag<=127;odd_tag<=127;end
  else begin
   request_sync<={request_sync[0],request_toggle};
   case(state)
    IDLE:if(enable&&(request_sync[1]!=ack_toggle))begin row<=requested_row;frame<=0;burst<=0;state<=ISSUE;end
    ISSUE:if(ready)state<=WAIT_DATA;
    WAIT_DATA:if(done)begin reply<=rdata;copy_index<=0;state<=COPY;end
    COPY:if(copy_index==7)begin
     if(burst==39)begin
      burst<=0;
      if(!frame)begin frame<=1;state<=ISSUE;end
      else begin if(row[0])odd_tag<=row;else even_tag<=row;
       ack_toggle<=request_sync[1];state<=IDLE;end
     end else begin burst<=burst+1'b1;state<=ISSUE;end
    end else copy_index<=copy_index+1'b1;
    default:state<=IDLE;
   endcase
  end
 end
endmodule

module sdram_media(
 input wire clk,rst_n,pixel_clk,pixel_rst_n,
 input wire we,bank,input wire [16:0] waddr,input wire [15:0] din,
 input wire [9:0] x,y,slide_offset,input wire front,slide_enable,
 input wire [1:0] effect,
 output wire word_ready,sector_ready,stored,initialized,error,
 output wire [23:0] rgb
);
 wire mr,md,ma,mem_req,upload_req,upload_write,upload_ready,upload_done;
 wire scan_req,scan_ready,scan_done;
 wire [20:0] upload_addr,scan_addr;
 wire [255:0] upload_data,rdata;
 reg owner;
 wire choose_scan=scan_req;
 assign mem_req=choose_scan?scan_req:upload_req;
 assign scan_ready=mr&&choose_scan;
 assign upload_ready=mr&&!choose_scan;
 assign scan_done=md&&owner;
 assign upload_done=md&&!owner;
 always @(posedge clk or negedge rst_n)
  if(!rst_n)owner<=0;else if(mr&&mem_req)owner<=choose_scan;
 wire sd_clk,ras,cas,mwe;wire [10:0] sa;wire [1:0] ba;wire [31:0] dq;
 sdram_burst u_mem(.clk(clk),.rst_n(rst_n),.req(mem_req),
  .write(!choose_scan&&upload_write),.addr(choose_scan?scan_addr:upload_addr),.wdata(upload_data),
  .ready(mr),.done(md),.initialized(initialized),.alignment_error(ma),.rdata(rdata),
  .sd_clk(sd_clk),.sd_ras_n(ras),.sd_cas_n(cas),.sd_we_n(mwe),.sd_addr(sa),.sd_ba(ba),.sd_dq(dq));
 sdram_sip u_sip(.sd_clk(sd_clk),.sd_ras_n(ras),.sd_cas_n(cas),.sd_we_n(mwe),.sd_addr(sa),.sd_ba(ba),.sd_dq(dq));
 wire upload_error,deadline_error;
 sdram_upload u_upload(.clk(clk),.rst_n(rst_n),.we(we),.bank(bank),.waddr(waddr),.din(din),
  .word_ready(word_ready),.sector_ready(sector_ready),.stored(stored),.error(upload_error),
  .req(upload_req),.write(upload_write),.addr(upload_addr),.wdata(upload_data),
  .ready(upload_ready),.done(upload_done),.rdata(rdata));
 sdram_bc1_raster u_raster(.clk(clk),.rst_n(rst_n),.pixel_clk(pixel_clk),.pixel_rst_n(pixel_rst_n),
  .enable(initialized),.x(x),.y(y),.slide_offset(slide_offset),.front(front),.slide_enable(slide_enable),
  .effect(effect),
  .rgb(rgb),.deadline_error(deadline_error),.req(scan_req),.addr(scan_addr),
  .ready(scan_ready),.done(scan_done),.rdata(rdata));
 reg [1:0] deadline_sync;
 always @(posedge clk or negedge rst_n)
  if(!rst_n)deadline_sync<=0;else deadline_sync<={deadline_sync[0],deadline_error};
 assign error=ma||upload_error||deadline_sync[1];
endmodule

// Coordinate-only transitions. Both frame banks are already cached for the
// current four scanlines: do not remap Y or issue additional SDRAM reads.
module photo_transition_map(
 input wire [9:0] x,y,progress,
 input wire [1:0] effect,
 input wire enable,front,
 output reg [9:0] mapped_x,
 output reg selected,
 output reg [2:0] shade
);
 wire [10:0] shifted={1'b0,x}+{1'b0,progress};
 // A bijective 10-bit affine hash gives stable, spatially scattered particles.
 wire [9:0] particle={x[4],y[3],x[2],y[5],x[6],y[1],x[0],y[0],x[1],y[2]};
 wire [19:0] scramble={10'd0,particle}*20'd405+20'd137;
 wire [12:0] rank_product={3'd0,scramble[9:0]}*13'd5;
 wire [9:0] rank=rank_product[12:3];
 wire [9:0] fold=(progress<320)?progress:10'd320;
 wire [10:0] flight=(progress<320)?11'd0:({1'b0,progress}-11'd320)<<1;
 // Signed screen-space projection: pitch the nose upwards while folding,
 // then move right/up at slope -3/4. Centers may leave the visible screen.
 wire signed [12:0] center_x=13'sd320+$signed({2'b00,flight});
 wire signed [12:0] center_y=13'sd240-$signed({2'b00,(flight>>1)})-
                                      $signed({2'b00,(flight>>2)});
 wire signed [12:0] u=$signed({3'b000,x})-center_x;
 wire signed [12:0] yy=$signed({3'b000,y})-center_y;
 wire [8:0] tilt=(fold<256)?fold[8:0]:9'd256;
 wire signed [22:0] tilt_product=u*$signed({1'b0,tilt});
 wire signed [12:0] v=yy+(tilt_product>>>9);
 wire [12:0] av=v[12]?-v:v;
 wire signed [12:0] left_edge= -13'sd320+$signed({3'b000,fold}>>1);
 wire [11:0] span=(progress<320)?12'd640-{2'd0,fold}:12'd320-({1'b0,flight}>>2);
 wire [22:0] corner=av*fold;
 wire [15:0] diagonal=corner[22:7];
 wire [15:0] distance_u=u-left_edge;
 wire tail_notch=(fold>=256)&&(distance_u<32)&&(av<8);
 wire on_paper=(span>diagonal)&&(u>=left_edge)&&
               (distance_u<span-diagonal)&&!tail_notch;
 // Offset cast shadow on the incoming frame provides a depth cue. It uses
 // the already cached background; no extra memory reads or frame buffer.
 wire signed [12:0] shadow_u=u-13'sd12,shadow_v=v-13'sd22;
 wire [12:0] shadow_av=shadow_v[12]?-shadow_v:shadow_v;
 wire [22:0] shadow_corner=shadow_av*fold;
 wire [15:0] shadow_diagonal=shadow_corner[22:7];
 wire [15:0] shadow_distance=shadow_u-left_edge;
 wire on_shadow=(fold>=128)&&(span>shadow_diagonal)&&
                (shadow_u>=left_edge)&&(shadow_distance<span-shadow_diagonal)&&
                !((fold>=256)&&(shadow_distance<32)&&(shadow_av<8));
 wire signed [23:0] source_x=24'sd320+u+(tilt_product>>>8);
 always @* begin
  mapped_x=x;selected=front;shade=0;
  if(enable&&(x<640)&&(y<480)) begin
   if(progress>=640) selected=~front;
   else if(progress!=0) case(effect)
    1:begin
     if(on_paper)begin
      mapped_x=(source_x<0)?10'd0:(source_x>639)?10'd639:source_x[9:0];
      // Perspective-like compression, mirrored far wing, lit ridge, pale
      // underside and a narrow edge highlight separate the paper facets.
      if((fold>=80)&&(v< -13'sd4))
       mapped_x=10'd639-mapped_x;
      if(fold>=80)shade=(v<0)?1:2;
      if((fold>=192)&&(v>0)&&(av>(span>>3))&&(distance_u<(span>>1)))shade=5;
      if((fold>=160)&&(av<3))shade=3;
      if((fold>=192)&&(span-diagonal-distance_u<3))shade=6;
     end else begin selected=~front;if(on_shadow)shade=4;end
    end
    2:if(rank<progress)selected=~front;
    default:begin
     mapped_x=(shifted>=640)?shifted-11'd640:shifted;
     selected=front^(shifted>=640);
    end
   endcase
  end
 end
endmodule
