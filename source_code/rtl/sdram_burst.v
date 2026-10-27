// EG4S20 SiP SDRAM, 50 MHz controller and same-phase memory clock.
// 8 x 32-bit sequential bursts. Addresses are 32-bit WORD addresses.
// Mapping: bank[20:19], row[18:8], column[7:0]. No external board IO.
// Closed-page scheduling deliberately trades peak speed for simple bounds.
module sdram_burst #(
    parameter POWER_CYCLES=10000,
    parameter REFRESH_CYCLES=750
)(
    input wire clk,rst_n,
    input wire req,write,
    input wire [20:0] addr,
    input wire [255:0] wdata,
    output wire ready,
    output reg initialized,done,alignment_error,
    output reg [255:0] rdata,
    output wire sd_clk,
    output reg sd_ras_n,sd_cas_n,sd_we_n,
    output reg [10:0] sd_addr,
    output reg [1:0] sd_ba,
    inout wire [31:0] sd_dq
);
    localparam POWER=0,INIT_PRE=1,INIT_REF=2,INIT_MODE=3,
               IDLE=4,RCD=5,READ_WAIT=6,READ_DATA=7,WRITE_DATA=8,
               RECOVER=9,PRE_WAIT=10,REF_WAIT=11;
    reg [3:0] state;
    reg [13:0] timer;
    reg [9:0] refresh_count;
    reg [3:0] refresh_left;
    reg [20:0] address;
    reg is_write,drive;
    reg [255:0] data;
    reg [31:0] dq_out;
    reg [2:0] command;
    reg [10:0] command_addr;
    reg [1:0] command_ba;
    reg pin_drive;
    reg [31:0] pin_dq;
    reg [2:0] index;
    assign sd_clk=clk;
    assign sd_dq=pin_drive?pin_dq:32'bz;
    // Launch commands and write data halfway between memory sampling edges.
    // This is a real edge separation, not an artificial false/multicycle path.
    always @(negedge clk or negedge rst_n)begin
        if(!rst_n)begin
            {sd_ras_n,sd_cas_n,sd_we_n}<=3'b111;
            sd_addr<=0;sd_ba<=0;pin_drive<=0;pin_dq<=0;
        end else begin
            {sd_ras_n,sd_cas_n,sd_we_n}<=command;
            sd_addr<=command_addr;sd_ba<=command_ba;
            pin_drive<=drive;pin_dq<=dq_out;
        end
    end
    assign ready=initialized&&(state==IDLE)&&(refresh_count<REFRESH_CYCLES);
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=POWER;timer<=0;refresh_count<=0;refresh_left<=8;
            initialized<=0;done<=0;alignment_error<=0;rdata<=0;
            command<=3'b111;command_addr<=0;command_ba<=0;
            address<=0;is_write<=0;drive<=0;data<=0;dq_out<=0;index<=0;
        end else begin
            command<=3'b111;
            done<=0;
            if(initialized&&(refresh_count<REFRESH_CYCLES)) refresh_count<=refresh_count+1'b1;
            case(state)
                POWER: if(timer==POWER_CYCLES-1) begin
                    command<=3'b010;
                    command_addr<=11'h400;timer<=3;state<=INIT_PRE;
                end else timer<=timer+1'b1;
                INIT_PRE: if(timer!=0)timer<=timer-1'b1;
                    else begin
                        command<=3'b001;
                        timer<=7;refresh_left<=7;state<=INIT_REF;
                    end
                INIT_REF: if(timer!=0)timer<=timer-1'b1;
                    else if(refresh_left!=0)begin
                        command<=3'b001;
                        refresh_left<=refresh_left-1'b1;timer<=7;
                    end else begin
                        command<=3'b000;
                        command_addr<=11'h033;command_ba<=0;timer<=3;state<=INIT_MODE;
                    end
                INIT_MODE: if(timer!=0)timer<=timer-1'b1;
                    else begin initialized<=1;refresh_count<=0;state<=IDLE;end
                IDLE: begin
                    drive<=0;
                    if(refresh_count>=REFRESH_CYCLES)begin
                        command<=3'b001;
                        refresh_count<=0;timer<=7;state<=REF_WAIT;
                    end else if(req) begin
                        if(addr[2:0]!=0)begin alignment_error<=1;done<=1;end
                        else begin
                            address<=addr;data<=wdata;is_write<=write;
                            command_ba<=addr[20:19];command_addr<=addr[18:8];
                            command<=3'b011;
                            timer<=2;state<=RCD;
                        end
                    end
                end
                RCD: if(timer!=0)timer<=timer-1'b1;
                    else begin
                        command_addr<={3'b000,address[7:0]};
                        if(is_write)begin
                            command<=3'b100;
                            drive<=1;dq_out<=data[31:0];index<=1;state<=WRITE_DATA;
                        end else begin
                            command<=3'b101;
                            timer<=3;index<=0;state<=READ_WAIT;
                        end
                    end
                WRITE_DATA:begin
                    dq_out<=data[index*32+:32];
                    if(index==7)begin timer<=3;state<=RECOVER;end
                    else index<=index+1'b1;
                end
                READ_WAIT:if(timer!=0)timer<=timer-1'b1;
                    else begin rdata[31:0]<=sd_dq;index<=1;state<=READ_DATA;end
                READ_DATA:begin
                    rdata[index*32+:32]<=sd_dq;
                    if(index==7)begin timer<=1;state<=RECOVER;end
                    else index<=index+1'b1;
                end
                RECOVER:begin
                    drive<=0;
                    if(timer!=0)timer<=timer-1'b1;
                    else begin
                        command<=3'b010;
                        command_addr<=11'h400;timer<=2;state<=PRE_WAIT;
                    end
                end
                PRE_WAIT:if(timer!=0)timer<=timer-1'b1;
                    else begin done<=1;state<=IDLE;end
                REF_WAIT:if(timer!=0)timer<=timer-1'b1;else state<=IDLE;
                default:state<=POWER;
            endcase
        end
    end
endmodule

// A wrapper for the actual chip primitive. The simulation uses the vendor
// IS42s32200 bus model instead; this wrapper has no behavioral memory fallback.
module sdram_sip(
    input wire sd_clk,sd_ras_n,sd_cas_n,sd_we_n,
    input wire [10:0] sd_addr,input wire [1:0] sd_ba,
    inout wire [31:0] sd_dq
);
    EG_PHY_SDRAM_2M_32 u_sip(
        .clk(sd_clk),.ras_n(sd_ras_n),.cas_n(sd_cas_n),.we_n(sd_we_n),
        .addr(sd_addr),.ba(sd_ba),.dq(sd_dq),.cs_n(1'b0),
        .dm0(1'b0),.dm1(1'b0),.dm2(1'b0),.dm3(1'b0),.cke(1'b1));
endmodule
