`timescale 1ns/1ps
module photo_slide_tb;
    reg clk=0;always #10 clk=~clk;
    reg rst=0,blank=0,loaded=0,n=0,p=0,ack=0;
    wire nl,pl,req,event_out,front,valid,write_bank;
    wire [9:0] offset;
    wire [31:0] base;
    integer ticks=0,nav=0,steps=0,previous_offset=0;
    reg previous_front;
    photo_slide dut(clk,rst,blank,loaded,n,p,nl,pl,offset,front,valid,write_bank,1'b0);
    image_controller control(.clk(clk),.rst_n(rst),.sd_init_done(1'b1),
        .key_press(nl),.previous_press(pl),.load_ack(ack),.load_req(req),
        .base_sector(base),.switch_event(event_out));
    always @(negedge clk) if(rst) begin
        ticks=ticks+1;blank=(ticks%20>=10);
        if(nl||pl) nav=nav+1;
    end
    task transition;
        input go_previous;
        input [31:0] expected_base;
        begin
            previous_front=front;
            @(negedge clk);p=go_previous;n=!go_previous;
            @(negedge clk);p=0;n=0;
            repeat(3) @(negedge clk);
            if(!valid||offset||front!=previous_front||write_bank==front||base!=expected_base)
                $fatal(1,"Preload lost old picture / chose wrong target");
            loaded=0;ack=1;
            repeat(80) @(negedge clk);
            n=1;@(negedge clk);n=0;
            repeat(100) @(negedge clk);
            if(!valid||offset||front!=previous_front) $fatal(1,"SD wait blanked/moved old picture");
            ack=0;loaded=1;wait(dut.phase==3);
            steps=0;previous_offset=0;
            while(dut.phase==3) begin
                @(posedge clk);
                if(dut.phase==3&&dut.tick) begin
                    steps=steps+1;#1;
                    if(steps<90) begin
                        if(offset<=previous_offset||offset-previous_offset>8||front!=previous_front||!valid)
                            $fatal(1,"Bad motion step or premature bank swap");
                        previous_offset=offset;
                    end
                end
            end
            if(steps!=90||offset!=0||front==previous_front||!valid||write_bank==front)
                $fatal(1,"Push did not end after exactly 90 refreshes / ownership wrong");
        end
    endtask
    initial begin
        #100;rst=1;repeat(8) @(negedge clk);
        if(valid||write_bank||base!=0||!req) $fatal(1,"Initial load must target A");
        ack=1;loaded=1;repeat(4) @(negedge clk);ack=0;
        transition(1,384); // image 1 -> previous image 4, preload B
        transition(0,0);   // image 4 -> next image 1, preload A
        if(nav!=2) $fatal(1,"Busy press unexpectedly queued another image");
        @(negedge clk);n=1;@(negedge clk);n=0;loaded=0;
        repeat(5) @(negedge clk);rst=0;#1;
        if(valid||offset||front||req) $fatal(1,"Reset/mode exit did not cancel preload");
        $display("PASS photo push: old frame retained through SD wait, 90 refreshes, A/B ping-pong, prev/next wrap, busy/reset");
        $finish;
    end
    initial begin #200000;$fatal(1,"Photo push timeout");end
endmodule
