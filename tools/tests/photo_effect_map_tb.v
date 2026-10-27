`timescale 1ns/1ps
module photo_effect_map_tb;
 reg [9:0] x=0,y=0,p=0;
 reg [1:0] effect=0;
 reg enable=1,front=0;
 wire [9:0] mx;wire selected;wire [2:0] shade;
 photo_transition_map dut(x,y,p,effect,enable,front,mx,selected,shade);
 integer e,f,xx,yy,k,n,old_count,last_count,checks=0;
 integer phases[0:6];
 initial begin
  phases[0]=0;phases[1]=80;phases[2]=160;phases[3]=320;
  phases[4]=480;phases[5]=639;phases[6]=640;
  for(e=0;e<3;e=e+1)for(f=0;f<2;f=f+1)begin
   effect=e;front=f;last_count=307201;
   for(k=0;k<7;k=k+1)begin
    p=phases[k];old_count=0;
    for(yy=0;yy<480;yy=yy+1)for(xx=0;xx<640;xx=xx+1)begin
     x=xx;y=yy;#1;checks=checks+1;
     if(mx>=640||(^mx===1'bx)||(^selected===1'bx)||(^shade===1'bx))
      $fatal(1,"Invalid coordinate effect=%d p=%d x=%d y=%d",e,p,x,y);
     if(selected==front)old_count=old_count+1;
     if(p==0&&(selected!==front||mx!=x||shade!=0))$fatal(1,"Initial endpoint mismatch");
     if(p==640&&(selected===front||mx!=x||shade!=0))$fatal(1,"Final endpoint mismatch");
     if(e==0&&p<640)begin
      n=xx+p;
      if(mx!=(n%640)||selected!==(front^(n>=640))||shade!=0)$fatal(1,"Slide regression");
     end
     if(e==2&&(mx!=x||shade!=0))$fatal(1,"Dissolve remaps/shades source");
    end
    if(e==2&&old_count>last_count)$fatal(1,"Dissolve is not monotonic");
    if(e==2&&p==320&&(old_count<140000||old_count>167000))$fatal(1,"Particle distribution bias");
    last_count=old_count;
    $display("CHECK effect=%0d front=%0d progress=%0d old_pixels=%0d",e,f,p,old_count);
   end
  end
  enable=0;effect=1;p=320;x=100;y=200;#1;
  if(mx!=x||selected!=front||shade!=0)$fatal(1,"Video bypass changed");
  $display("PASS all three maps: %0d pixel checks, both banks, endpoints, boundaries, dissolve distribution, video bypass",checks);
  $finish;
 end
endmodule
