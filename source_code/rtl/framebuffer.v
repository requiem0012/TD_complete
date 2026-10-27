// ============================================================================
// framebuffer.v - banked dual-clock RGB565 frame buffer.
//
// The 200x150 image is split into four parity banks:
//   bank00 = even row/even column, bank01 = even row/odd column
//   bank10 = odd row/even column,  bank11 = odd row/odd column
// Each bank stores 100x75 RGB565 pixels. The four independent read ports let
// vga_disp fetch a 2x2 neighbourhood in one pixel clock for bilinear scaling.
// Total storage is unchanged: 4 * 7500 * 16 bits. With TD's power-of-two RAM
// rounding this is 4 * 8192 * 16 = 524288 bits, safely inside the device.
//
// RGB565 layout: [15:11] red, [10:5] green, [4:0] blue.
// ============================================================================

module framebuffer #(
    parameter BANK_DEPTH = 8192, // physical depth; 7500 pixels used per bank
    parameter ADDR_W     = 13,
    parameter USE_32K    = 0,
    parameter AUX_READ   = 0
)(
    input  wire               wr_clk,
    input  wire               wr_en,
    input  wire [14:0]        wr_addr,
    input  wire [15:0]        wr_data,

    input  wire               rd_clk,
    input  wire [ADDR_W-1:0]  rd_addr00,
    input  wire [ADDR_W-1:0]  rd_addr01,
    input  wire [ADDR_W-1:0]  rd_addr10,
    input  wire [ADDR_W-1:0]  rd_addr11,
    output wire [15:0]        rd_data00,
    output wire [15:0]        rd_data01,
    output wire [15:0]        rd_data10,
    output wire [15:0]        rd_data11,
    input wire [12:0]         aux_addr,
    output wire [15:0]        aux00,aux01,aux10,aux11
);

    reg [7:0]        wr_x;
    reg              wr_y_odd;
    reg [ADDR_W-1:0] wr_ptr00, wr_ptr01, wr_ptr10, wr_ptr11;

    // A single syntactic write port per bank is required for block RAM
    // inference. Route the first pixel through the SAME port as every other
    // write; do not add a separate mem00[0] assignment in the control process.
    wire first_pixel = (wr_addr == 15'd0);
    wire we00 = wr_en && (first_pixel || (!wr_y_odd && !wr_x[0]));
    wire we01 = wr_en && !first_pixel && !wr_y_odd &&  wr_x[0];
    wire we10 = wr_en && !first_pixel &&  wr_y_odd && !wr_x[0];
    wire we11 = wr_en && !first_pixel &&  wr_y_odd &&  wr_x[0];
    wire [ADDR_W-1:0] wa00 = first_pixel ? {ADDR_W{1'b0}} : wr_ptr00;

    generate if (!USE_32K) begin : inferred9k
    assign {aux00,aux01,aux10,aux11}=64'd0;
    reg [15:0] mem00 [0:BANK_DEPTH-1];
    reg [15:0] mem01 [0:BANK_DEPTH-1];
    reg [15:0] mem10 [0:BANK_DEPTH-1];
    reg [15:0] mem11 [0:BANK_DEPTH-1];
    reg [15:0] q00,q01,q10,q11;
    assign rd_data00=q00;assign rd_data01=q01;
    assign rd_data10=q10;assign rd_data11=q11;
    always @(posedge rd_clk) begin
        q00<=mem00[rd_addr00];q01<=mem01[rd_addr01];
        q10<=mem10[rd_addr10];q11<=mem11[rd_addr11];
    end
    always @(posedge wr_clk) begin
        if (we00) mem00[wa00] <= wr_data;
    end
    always @(posedge wr_clk) begin
        if (we01) mem01[wr_ptr01] <= wr_data;
    end
    always @(posedge wr_clk) begin
        if (we10) mem10[wr_ptr10] <= wr_data;
    end
    always @(posedge wr_clk) begin
        if (we11) mem11[wr_ptr11] <= wr_data;
    end
    end else begin : explicit32k
        wire [3:0] we = {we11,we10,we01,we00};
        wire [12:0] wa [0:3];
        wire [12:0] ra [0:3];
        wire [15:0] q [0:3];
        wire [15:0] aq [0:3];
        assign aux00=aq[0];assign aux01=aq[1];
        assign aux10=aq[2];assign aux11=aq[3];
        assign wa[0]=wa00;assign wa[1]=wr_ptr01;
        assign wa[2]=wr_ptr10;assign wa[3]=wr_ptr11;
        assign ra[0]=rd_addr00;assign ra[1]=rd_addr01;
        assign ra[2]=rd_addr10;assign ra[3]=rd_addr11;
        assign rd_data00=q[0];assign rd_data01=q[1];
        assign rd_data10=q[2];assign rd_data11=q[3];
        genvar b,s;
        for(b=0;b<4;b=b+1) begin : parity
            wire [15:0] subq [0:3];
            wire [15:0] suba [0:3];
            // Port A remains 50 MHz. Between loads it is also the video-copy
            // read port. Port B remains 25 MHz for the photo/display raster.
            wire [12:0] pa=(AUX_READ&&!wr_en)?aux_addr:wa[b];
            reg [1:0] select_d,select_a;
            always @(posedge rd_clk) select_d<=ra[b][12:11];
            always @(posedge wr_clk) select_a<=pa[12:11];
            assign q[b]=subq[select_d];
            assign aq[b]=AUX_READ?suba[select_a]:16'd0;
            for(s=0;s<4;s=s+1) begin : chunk
                EG_LOGIC_BRAM #(
                    .DATA_WIDTH_A(16),.DATA_WIDTH_B(16),
                    .ADDR_WIDTH_A(11),.ADDR_WIDTH_B(11),
                    .DATA_DEPTH_A(2048),.DATA_DEPTH_B(2048),
                    .MODE("DP"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
                    .IMPLEMENT("32K")
                ) ram (
                    .dia(wr_data),.dib(16'd0),.addra(pa[10:0]),.addrb(ra[b][10:0]),
                    .cea(1'b1),.ceb(1'b1),.ocea(1'b1),.oceb(1'b1),
                    .clka(wr_clk),.clkb(rd_clk),.wea(we[b]&&(wa[b][12:11]==s)),
                    .web(1'b0),.rsta(1'b0),.rstb(1'b0),.bea(1'b1),.beb(1'b1),
                    .doa(suba[s]),.dob(subq[s])
                );
            end
        end
    end endgenerate

    // The loader writes pixels in strict row-major order. Tracking parity and
    // one sequential pointer per bank avoids division/modulo logic in hardware.

    always @(posedge wr_clk) begin
        if (wr_en) begin
            // Address zero marks the start of every newly loaded image.
            if (wr_addr == 15'd0) begin
                wr_x     <= 8'd1;
                wr_y_odd <= 1'b0;
                wr_ptr00 <= {{(ADDR_W-1){1'b0}}, 1'b1};
                wr_ptr01 <= {ADDR_W{1'b0}};
                wr_ptr10 <= {ADDR_W{1'b0}};
                wr_ptr11 <= {ADDR_W{1'b0}};
            end
            else begin
                case ({wr_y_odd, wr_x[0]})
                    2'b00: begin
                        wr_ptr00 <= wr_ptr00 + 1'b1;
                    end
                    2'b01: begin
                        wr_ptr01 <= wr_ptr01 + 1'b1;
                    end
                    2'b10: begin
                        wr_ptr10 <= wr_ptr10 + 1'b1;
                    end
                    2'b11: begin
                        wr_ptr11 <= wr_ptr11 + 1'b1;
                    end
                endcase

                if (wr_x == 8'd199) begin
                    wr_x     <= 8'd0;
                    wr_y_odd <= ~wr_y_odd;
                end
                else begin
                    wr_x <= wr_x + 1'b1;
                end
            end
        end
    end

endmodule

// 416x312 BC1 cache: 104x78 blocks, 2028 blocks per parity bank.
// Assemble four incoming little-endian 16-bit words atomically into one block.
// A uses 64 explicit 9K RAMs (16-bit x 512); B uses sixteen 32K RAMs.
module bc1_framebuffer #(parameter USE_32K=0)(
    input wire wr_clk,wr_en,
    input wire [14:0] wr_addr,
    input wire [15:0] wr_data,
    input wire rd_clk,
    input wire [10:0] rd_addr00,rd_addr01,rd_addr10,rd_addr11,
    output wire [63:0] rd_data00,rd_data01,rd_data10,rd_data11,
    input wire [10:0] aux_addr,
    output wire [63:0] aux00,aux01,aux10,aux11
);
    reg [15:0] lane0,lane1,lane2;
    reg [6:0] block_x;
    reg row_odd;
    reg [10:0] ptr00,ptr01,ptr10,ptr11;
    wire commit=wr_en&&(wr_addr[1:0]==3);
    wire [1:0] bank={row_odd,block_x[0]};
    wire [63:0] block_data={wr_data,lane2,lane1,lane0};
    wire [10:0] wa [0:3];
    wire [10:0] ra [0:3];
    wire [63:0] q [0:3];
    wire [63:0] aq [0:3];
    assign wa[0]=ptr00;assign wa[1]=ptr01;assign wa[2]=ptr10;assign wa[3]=ptr11;
    assign ra[0]=rd_addr00;assign ra[1]=rd_addr01;assign ra[2]=rd_addr10;assign ra[3]=rd_addr11;
    assign rd_data00=q[0];assign rd_data01=q[1];assign rd_data10=q[2];assign rd_data11=q[3];
    assign aux00=aq[0];assign aux01=aq[1];assign aux10=aq[2];assign aux11=aq[3];
    always @(posedge wr_clk) if(wr_en) begin
        case(wr_addr[1:0]) 0:lane0<=wr_data;1:lane1<=wr_data;2:lane2<=wr_data;endcase
        if(wr_addr==0) begin
            block_x<=0;row_odd<=0;ptr00<=0;ptr01<=0;ptr10<=0;ptr11<=0;
        end else if(commit) begin
            case(bank)
                0:ptr00<=ptr00+1'b1;1:ptr01<=ptr01+1'b1;
                2:ptr10<=ptr10+1'b1;3:ptr11<=ptr11+1'b1;
            endcase
            if(block_x==103) begin block_x<=0;row_odd<=~row_odd;end
            else block_x<=block_x+1'b1;
        end
    end
    genvar b,l,s;
    generate for(b=0;b<4;b=b+1) begin:bc_bank
        if(USE_32K) begin:ram32
            wire [63:0] unused;
            wire [10:0] pa=commit?wa[b]:aux_addr;
            for(l=0;l<4;l=l+1) begin:lane
                EG_LOGIC_BRAM #(.DATA_WIDTH_A(16),.DATA_WIDTH_B(16),
                    .ADDR_WIDTH_A(11),.ADDR_WIDTH_B(11),.DATA_DEPTH_A(2048),.DATA_DEPTH_B(2048),
                    .MODE("DP"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.IMPLEMENT("32K")) ram (
                    .dia(block_data[l*16+:16]),.dib(16'd0),.addra(pa),.addrb(ra[b]),
                    .cea(1'b1),.ceb(1'b1),.ocea(1'b1),.oceb(1'b1),.clka(wr_clk),.clkb(rd_clk),
                    .wea(commit&&(bank==b)),.web(1'b0),.rsta(1'b0),.rstb(1'b0),.bea(1'b1),.beb(1'b1),
                    .doa(aq[b][l*16+:16]),.dob(q[b][l*16+:16]));
            end
        end else begin:ram9
            wire [63:0] subq [0:3];
            reg [1:0] select_d;
            always @(posedge rd_clk) select_d<=ra[b][10:9];
            assign q[b]=subq[select_d];
            assign aq[b]=0;
            for(l=0;l<4;l=l+1) begin:lane
                for(s=0;s<4;s=s+1) begin:chunk
                    EG_LOGIC_BRAM #(.DATA_WIDTH_A(16),.DATA_WIDTH_B(16),
                        .ADDR_WIDTH_A(9),.ADDR_WIDTH_B(9),.DATA_DEPTH_A(512),.DATA_DEPTH_B(512),
                        .MODE("DP"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.IMPLEMENT("9K")) ram (
                        .dia(block_data[l*16+:16]),.dib(16'd0),.addra(wa[b][8:0]),.addrb(ra[b][8:0]),
                        .cea(1'b1),.ceb(1'b1),.ocea(1'b1),.oceb(1'b1),.clka(wr_clk),.clkb(rd_clk),
                        .wea(commit&&(bank==b)&&(wa[b][10:9]==s)),.web(1'b0),
                        .rsta(1'b0),.rstb(1'b0),.bea(1'b1),.beb(1'b1),
                        .doa(),.dob(subq[s][l*16+:16]));
                end
            end
        end
    end endgenerate
endmodule

// Copy a fully verified back frame to the 9K display RAM during vertical blank.
// Back RAM and copy engine share the 50 MHz clock; display stays at 25 MHz.
// 32450 cycles (~0.649 ms) fit inside 45*800/25MHz = 1.44 ms blanking.
module video_frame_presenter (
    input wire clk,rst_n,vblank,request,
    output reg ack,
    output wire [10:0] back_addr,
    input wire [63:0] back00,back01,back10,back11,
    output wire front_we,
    output reg [14:0] front_addr,
    output wire [15:0] front_data,
    output reg busy,timing_error,
    input wire load_we,
    input wire [14:0] load_addr,
    input wire [15:0] load_data
);
    (* async_reg="true" *) reg [2:0] blank_sync;
    reg [2:0] blank_valid;
    reg blank_armed;
    reg issue,valid_d,check_pending;
    reg [14:0] index;
    reg [7:0] x;
    reg row_odd;
    reg [12:0] row_base;
    reg [1:0] parity_d,lane_d;
    reg [1:0] word_lane;
    reg [31:0] load_crc,expected_crc,copy_crc;
    function [31:0] crc_word;
        input [31:0] crc;
        input [15:0] data;
        reg [31:0] value;
        reg [7:0] byte_value;
        integer byte_no,bit_no;
        begin
            value=crc;
            for(byte_no=0;byte_no<2;byte_no=byte_no+1) begin
                byte_value=byte_no?data[15:8]:data[7:0];
                value=value^{24'd0,byte_value};
                for(bit_no=0;bit_no<8;bit_no=bit_no+1)
                    value=value[0]?((value>>1)^32'hedb88320):(value>>1);
            end
            crc_word=value;
        end
    endfunction
    wire [31:0] next_load_crc=crc_word((load_addr==0)?32'hffffffff:load_crc,load_data);
    wire [31:0] next_copy_crc=crc_word(copy_crc,front_data);
    wire blank_rise=blank_sync[1]&&!blank_sync[2];
    assign back_addr=row_base[10:0]+{4'd0,x[7:1]};
    wire [63:0] back_block=(parity_d==0)?back00:(parity_d==1)?back01:
                            (parity_d==2)?back10:back11;
    assign front_we=valid_d&&rst_n;
    assign front_data=back_block[lane_d*16+:16];
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            blank_sync<=0;blank_valid<=0;blank_armed<=0;
            issue<=0;valid_d<=0;check_pending<=0;index<=0;x<=0;row_odd<=0;
            row_base<=0;parity_d<=0;word_lane<=0;lane_d<=0;front_addr<=0;ack<=0;busy<=0;timing_error<=0;
            load_crc<=32'hffffffff;expected_crc<=0;copy_crc<=32'hffffffff;
        end else begin
            blank_sync<={blank_sync[1:0],vblank};
            blank_valid<={blank_valid[1:0],1'b1};
            // Reset/replay may be released halfway through a blank interval.
            // Observe a real active interval before accepting the next rising edge.
            if(blank_valid[2]&&!blank_sync[1]) blank_armed<=1;
            valid_d<=issue;
            if(load_we) begin
                load_crc<=next_load_crc;
                if(load_addr==32447) expected_crc<=~next_load_crc;
                if(busy) timing_error<=1;
            end
            if(blank_rise&&blank_armed&&!busy&&(request!=ack)) begin
                busy<=1;issue<=1;index<=0;x<=0;row_odd<=0;row_base<=0;word_lane<=0;
                copy_crc<=32'hffffffff;
            end
            if(issue) begin
                // Metadata is delayed by the same one cycle as the BRAM read.
                front_addr<=index;parity_d<={row_odd,x[0]};lane_d<=word_lane;
                word_lane<=word_lane+1'b1;
                if(index==32447) issue<=0;
                else index<=index+1'b1;
                if(word_lane==3) begin
                    if(x==103) begin
                        x<=0;row_odd<=~row_odd;
                        if(row_odd) row_base<=row_base+13'd52;
                    end else x<=x+1'b1;
                end
            end
            if(valid_d&&(front_addr==32447)) begin
                check_pending<=1;
            end
            if(check_pending) begin
                ack<=request;busy<=0;
                check_pending<=0;
                // Detect silent RAM corruption independently of SD transfer CRC16.
                // Compare registered CRC one cycle later, not on the BRAM read path.
                if((~copy_crc)!=expected_crc) timing_error<=1;
            end
            if(valid_d) copy_crc<=next_copy_crc;
            if(busy&&!blank_sync[1]) timing_error<=1;
        end
    end
endmodule
