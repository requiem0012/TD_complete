`timescale 1ns/1ps
// SPI mode-3 card model: unlike sd_capacity_tb this never forces transport ACK.
module sd_spi_pins_tb;
    reg clk=0;always #10 clk=~clk;
    reg rst=1,req=0,miso=1;
    reg [31:0] lba=0;
    wire cs,sck,mosi,init,valid,done,error;
    wire [7:0] data;
    wire [32:0] capacity;
    sd_card_top dut(.clk(clk),.rst(rst),.video_speed(1'b1),.card_sectors(capacity),
        .SD_nCS(cs),.SD_DCLK(sck),.SD_MOSI(mosi),.SD_MISO(miso),.sd_init_done(init),
        .sd_sec_read(req),.sd_sec_read_addr(lba),.sd_sec_read_data(data),
        .sd_sec_read_data_valid(valid),.sd_sec_read_end(done),
        .sd_sec_write(1'b0),.sd_sec_write_addr(32'd0),.sd_sec_write_data(8'd0),
        .sd_sec_write_data_req(),.sd_sec_write_end(),.sd_read_error(error));
    reg [7:0] response [0:1023];
    reg [7:0] packet [0:5];
    reg [7:0] incoming=0;
    reg [127:0] csd=0;
    reg [15:0] crc;
    reg [6:0] c7;
    reg [31:0] arg;
    integer bitn=0,cmdn=0,rpos=0,rlen=0,i,attempts=0,errors=0,index=0,scenario=0;
    integer cycles=0,start_cycle=0;
    always @(posedge clk) cycles=cycles+1;
    function [15:0] crc16;
        input [15:0] c;input [7:0] b;reg [15:0] x;integer k;
        begin x=c^{b,8'd0};for(k=0;k<8;k=k+1)x=x[15]?((x<<1)^16'h1021):(x<<1);crc16=x;end
    endfunction
    function [6:0] crc7;
        input [6:0] c;input [7:0] b;reg [6:0] x;integer k;
        begin x=c;for(k=7;k>=0;k=k-1)x=(x[6]^b[k])?((x<<1)^7'h09):(x<<1);crc7=x;end
    endfunction
    function [7:0] payload;
        input [31:0] a;
        input integer j;
        begin payload=(a^(a>>8)^(a>>16)^(a>>24)^j^(j>>8)^32'ha5)&255;end
    endfunction
    task command_reply;
        begin
            c7=0;for(i=0;i<5;i=i+1)c7=crc7(c7,packet[i]);
            if(packet[5]!=={c7,1'b1}) $fatal(1,"SPI pin command CRC7 failed");
            arg={packet[1],packet[2],packet[3],packet[4]};rpos=0;
            response[0]=0;rlen=1;
            case(packet[0]&63)
                0:response[0]=1;
                8:begin rlen=5;response[0]=1;response[1]=0;response[2]=0;response[3]=1;response[4]=8'haa;end
                55,41,59:response[0]=0;
                58:begin rlen=5;response[1]=8'hc0;response[2]=0;response[3]=0;response[4]=0;end
                9:begin
                    rlen=20;response[1]=8'hfe;crc=0;
                    for(i=0;i<16;i=i+1) begin
                        response[2+i]=csd[127-i*8-:8];crc=crc16(crc,response[2+i]);
                    end
                    response[18]=crc[15:8];response[19]=crc[7:0];
                end
                17:begin
                    if(arg!==lba) $fatal(1,"SPI pins changed 32-bit LBA got=%h expected=%h",arg,lba);
                    attempts=attempts+1;rlen=516;response[1]=8'hfe;crc=0;
                    for(i=0;i<512;i=i+1) begin response[2+i]=payload(arg,i);crc=crc16(crc,response[2+i]);end
                    response[514]=crc[15:8];response[515]=crc[7:0];
                    if(attempts==1) begin response[139]=response[139]^8'h04;errors=errors+1;end
                end
                default:$fatal(1,"Unsupported card command %h",packet[0]);
            endcase
        end
    endtask
    // Host samples on rising SCK. Card launches each next bit on falling SCK.
    always @(negedge sck) if(!cs)
        miso=(rlen>0)?response[rpos][7-bitn]:1'b1;
    always @(posedge cs) begin bitn=0;cmdn=0;rpos=0;rlen=0;incoming=0;miso=1;end
    always @(posedge sck) if(!cs) begin
        incoming={incoming[6:0],mosi};
        if(bitn==7) begin
            bitn=0;
            if(rlen>0) begin
                rpos=rpos+1;
                if(rpos==rlen) begin rlen=0;rpos=0;end
            end else if(cmdn!=0||incoming[7:6]==2'b01) begin
                packet[cmdn]=incoming;cmdn=cmdn+1;
                if(cmdn==6) begin cmdn=0;command_reply;end
            end
        end else bitn=bitn+1;
    end
    always @(posedge clk) if(valid) begin
        req<=0;
        if(data!==payload(lba,index)) $fatal(1,"Pin-level sector mismatch index=%0d",index);
        index=index+1;
    end
    initial begin
        csd[127:126]=1;csd[69:48]=65535;
        #100;rst=0;wait(init);
        for(scenario=0;scenario<7;scenario=scenario+1) begin
            @(negedge clk);index=0;
            case(scenario)
                0:lba=32'h00900000;
                1:lba=32'h00900001+53*152;
                2:lba=32'h00900001+54*152;
                3:lba=32'h00900001+56*152;
                4:lba=32'h00900001+57*152;
                5:lba=32'h00900001;
                6:lba=32'h00900001+56*152+128;
            endcase
            start_cycle=cycles;req=1;wait(done);@(negedge clk);
            $display("SPI sector=%0d cycles=%0d divider=%0d",scenario,cycles-start_cycle,dut.spi_div);
            if(index!=512) $fatal(1,"Pin-level bad payload count %0d",index);
            repeat(8) @(negedge clk);
        end
        if(attempts!=8||errors!=1||!dut.video_slow) $fatal(1,"Pin-level retry/fallback not exercised");
        $display("PASS SPI pins mode3 full commands/CRC, bad wire byte retried, same LBA, frame 53/54/56/57 and loop-back, 7 sectors");
        $finish;
    end
    initial begin #200000000;$fatal(1,"SPI card-model timeout state=%0d cmd=%0d bit=%0d",dut.state,dut.command_id,bitn);end
endmodule
