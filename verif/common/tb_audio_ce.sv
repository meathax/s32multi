`timescale 1ns/1ps
module tb_audio_ce;
reg clk=0,reset=1,pll_locked=0,is_multi32=0; always #5 clk=~clk;
wire z80,fm,pcm;
s32_audio_ce dut(.clk(clk),.reset(reset),.pll_locked(pll_locked),
 .is_multi32(is_multi32),.ce_z80(z80),.ce_fm(fm),.ce_pcm(pcm));
longint unsigned zsum, fsum, psum;
integer tick,zcount,pcount,zprev,fprev,pprev,errors;
initial begin
 zsum=0;fsum=0;psum=0;zcount=0;pcount=0;errors=0;
 repeat(3)@(negedge clk); pll_locked=1;
 // FM alone runs during board reset; the reset-gated domains remain phased 0.
 for(tick=1;tick<=20;tick=tick+1)begin
   fprev=fsum>>32; fsum=fsum+64'd715924818; @(negedge clk);
   if(fm!==((fsum>>32)!=fprev)||z80!==0||pcm!==0)$fatal(1,"reset phase policy tick %0d",tick);
 end
 reset=0;
 for(tick=1;tick<=10000;tick=tick+1)begin
   zprev=zsum>>32; fprev=fsum>>32; pprev=psum>>32;
   zsum=zsum+64'd715924818; fsum=fsum+64'd715924818; psum=psum+64'd1111135834;
   @(negedge clk);
   if(z80!==((zsum>>32)!=zprev))begin $display("FAIL Z80 tick %0d",tick);errors=errors+1;end
   if(fm!==((fsum>>32)!=fprev))begin $display("FAIL FM tick %0d",tick);errors=errors+1;end
   if(pcm!==((psum>>32)!=pprev))begin $display("FAIL PCM tick %0d",tick);errors=errors+1;end
   if(z80)zcount=zcount+1;if(pcm)pcount=pcount+1;
   if((tick==947||tick==7385) &&
      (zcount!==(zsum>>32)||pcount!==(psum>>32)))$fatal(1,"ordinal checkpoint tick %0d",tick);
 end
 if(zcount!==(zsum>>32)||pcount!==(psum>>32))$fatal(1,"pulse count mismatch");
 if(errors)$fatal(1,"AUDIO CE FAIL %0d",errors);
 $display("AUDIO CE PASS ticks=%0d z80=%0d pcm=%0d",tick-1,zcount,pcount);$finish;
end
endmodule
