`timescale 1ns/1ps
// Byte-transport model exercises actual command/CSD/CRC/retry state machines.
// This test bypasses SPI pin timing, which still requires board verification.
module sd_capacity_tb;
    reg clk=0;always #10 clk=~clk;
    reg rst=1,request=0,ack=0;
    reg [7:0] rx=255;
    wire init,valid,done,error;
    wire [7:0] data;
    wire [32:0] sectors;
    reg [127:0] csd=0;
    integer starts=0,attempt=0,count=0,completed=0,j;
    integer cache_fault=0,injected=0;
    reg [6:0] cmdcrc=0;
    reg [15:0] crc_csd,crc_payload;
    sd_card_top dut(.clk(clk),.rst(rst),.video_speed(1'b1),.card_sectors(sectors),
        .SD_nCS(),.SD_DCLK(),.SD_MOSI(),.SD_MISO(1'b1),.sd_init_done(init),
        .sd_sec_read(request),.sd_sec_read_addr(32'hf1234567),
        .sd_sec_read_data(data),.sd_sec_read_data_valid(valid),.sd_sec_read_end(done),
        .sd_sec_write(1'b0),.sd_sec_write_addr(32'd0),.sd_sec_write_data(8'd0),
        .sd_sec_write_data_req(),.sd_sec_write_end(),.sd_read_error(error));
    function [15:0] crc16;
        input [15:0] c;input [7:0] b;reg [15:0] x;integer k;
        begin x=c^{b,8'd0};for(k=0;k<8;k=k+1)x=x[15]?((x<<1)^16'h1021):(x<<1);crc16=x;end
    endfunction
    function [6:0] crc7;
        input [6:0] c;input [7:0] b;reg [6:0] x;integer k;
        begin x=c;for(k=7;k>=0;k=k-1)x=(x[6]^b[k])?((x<<1)^7'h09):(x<<1);crc7=x;end
    endfunction
    initial begin
        if($value$plusargs("CACHE=%d",cache_fault)) begin end
        force dut.spi_ack=ack;force dut.spi_rx=rx;
        csd[127:126]=1;csd[69:48]=22'd65535;
        crc_csd=0;crc_payload=0;
        for(j=0;j<16;j=j+1)crc_csd=crc16(crc_csd,csd[127-j*8-:8]);
        for(j=0;j<512;j=j+1)crc_payload=crc16(crc_payload,(j&255)^8'ha5);
        #100;rst=0;
        wait(init);if(sectors!==33'd67108864)$fatal(1,"Wrong CSD capacity %d",sectors);
        request=1;
        forever begin
            wait(done);@(negedge clk);
            if(count!=512)$fatal(1,"Bad byte count %d",count);
            completed=completed+1;count=0;
            if(completed==2)begin
                if(attempt<(cache_fault?7:6)||starts<2)$fatal(1,"Retry/reinit/cache verification not exercised");
                if(cache_fault&&!injected) $fatal(1,"Sector RAM fault not injected");
                if(!dut.video_slow||dut.spi_div!=1)$fatal(1,"Video speed fallback not retained after recovery");
                $display("PASS SD CSD CRC7 CRC16 retry/reinit/cache readback capacity=%d commands=%d cache_fault=%0d",sectors,attempt,cache_fault);$finish;
            end
            repeat(3)@(negedge clk);request=1;
        end
    end
    initial forever begin
        @(negedge clk);
        if(!rst&&dut.spi_req&&!ack) begin
            rx=255;
            case(dut.state)
                3:begin
                    if(dut.command_index==0)cmdcrc=0;
                    if(dut.command_index<5)cmdcrc=crc7(cmdcrc,dut.spi_tx);
                    else if(dut.spi_tx!=={cmdcrc,1'b1})$fatal(1,"Bad command CRC7");
                end
                4:begin
                    case(dut.command_id)
                        0:begin rx=1;starts=starts+1;end
                        8:rx=1;
                        17:begin rx=0;attempt=attempt+1;
                            if(dut.command_arg!==32'hf1234567)$fatal(1,"Changed LBA on retry");end
                        default:rx=0;
                    endcase
                end
                5:if(dut.command_id==8)begin
                    case(dut.ext_count)0:rx=0;1:rx=0;2:rx=1;3:rx=8'haa;endcase
                end else rx=(dut.ext_count==0)?8'hc0:0;
                8,15:rx=8'hfe;
                9:rx=dut.data_index[7:0]^8'ha5;
                10:rx=crc_payload[15:8];
                11:rx=crc_payload[7:0]^((attempt<=4)?8'h01:8'h00);
                16:rx=csd[127-dut.csd_index*8-:8];
                17:rx=crc_csd[15:8];
                18:rx=crc_csd[7:0];
            endcase
            repeat(2)@(negedge clk);
            ack=1;
            @(negedge clk);ack=0;
        end
    end
    always @(posedge clk)if(valid)begin
        if(cache_fault&&attempt==5) $fatal(1,"Corrupted cache sector leaked a valid byte");
        request<=0;
        if(data!==((count&255)^8'ha5))$fatal(1,"Bad/duplicate emitted payload");
        count=count+1;
    end
    always @(negedge clk) if(cache_fault&&!injected&&attempt==5&&dut.state==20) begin
        dut.sector_buffer[201]=dut.sector_buffer[201]^8'h01;injected=1;
    end
    initial begin #20000000;$fatal(1,"SD test timeout");end
endmodule
