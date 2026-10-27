`timescale 1ns/1ps
// End-to-end framebuffer -> scaler pixel check (public RAM model, not silicon).
module video_render_tb;
    reg wc=0,rc=0;always #10 wc=~wc;always #20 rc=~rc;
    reg reset_n=0,we=0,bank=0;
    reg [14:0] wa=0;reg [15:0] wd=0;
    reg [9:0] tx=0,ty=0;
    wire [12:0] a0,a1,a2,a3;
    wire [15:0] p0,p1,p2,p3,q0,q1,q2,q3;
    wire [7:0] r,g,b;
    framebuffer a(wc,we,wa,wd,rc,a0,a1,a2,a3,p0,p1,p2,p3,13'd0,,,,);
    framebuffer #(.USE_32K(1)) z(wc,we,wa,wd,rc,a0,a1,a2,a3,q0,q1,q2,q3,13'd0,,,,);
    vga_disp scale(rc,reset_n,tx,ty,bank?q0:p0,bank?q1:p1,bank?q2:p2,bank?q3:p3,
                   a0,a1,a2,a3,r,g,b,10'd0,1'b0,1'b0,);
    integer frame,backend,i,x,y,lx,ly,px,py,seed,checked;
    reg [23:0] current,previous;
    reg previous_active;
    function [7:0] channel;
        input integer x,y,c;
        reg [15:0] v;
        begin
            v=(y*200+x)^seed;
            case(c)
                0: channel={v[15:11],v[15:13]};
                1: channel={v[10:5],v[10:9]};
                2: channel={v[4:0],v[4:2]};
            endcase
        end
    endfunction
    function [23:0] reference;
        input integer ox,oy;
        integer sx,sy,nx,ny,fx,fy,c,t,d,value;
        begin
            sx=ox*5/16;sy=oy*5/16;fx=ox*5%16;fy=oy*5%16;
            nx=(sx==199)?199:sx+1;ny=(sy==149)?149:sy+1;
            for(c=0;c<3;c=c+1) begin
                t=channel(sx,sy,c)*(16-fx)+channel(nx,sy,c)*fx;
                d=channel(sx,ny,c)*(16-fx)+channel(nx,ny,c)*fx;
                value=(t*(16-fy)+d*fy+128)>>8;
                reference[23-c*8-:8]=value;
            end
        end
    endfunction
    initial begin
        for(frame=0;frame<2;frame=frame+1) begin
            seed=frame*16'h55aa;
            for(i=0;i<30000;i=i+1) begin
                @(negedge wc);we=1;wa=i;wd=i^seed;
            end
            @(negedge wc);we=0;
            for(backend=0;backend<2;backend=backend+1) begin
                reset_n=0;bank=backend;
                repeat(3) @(negedge rc);
                reset_n=1;previous_active=0;checked=0;
                for(i=0;i<420001;i=i+1) begin
                    @(negedge rc);
                    tx=i%800;ty=(i/800)%525;
                    lx=(tx==799)?0:tx+1;
                    ly=(tx==799)?((ty==524)?0:ty+1):ty;
                    px=(lx<640)?lx:0;py=(ly<480)?ly:0;
                    current=reference(px,py);
                    @(posedge rc);#1;
                    if(previous_active) begin
                        if({r,g,b}!==previous) $fatal(1,"Renderer frame=%0d RAM=%0d cycle=%0d got=%h expected=%h",frame,backend,i,{r,g,b},previous);
                        checked=checked+1;
                    end
                    previous=current;previous_active=(i<420000)&&(lx<640)&&(ly<480);
                end
                if(checked!=307200) $fatal(1,"Wrong renderer check count %0d",checked);
                $display("PASS renderer frame=%0d RAM=%0d all 307200 RGB888 pixels",frame,backend);
            end
        end
        $finish;
    end
endmodule
