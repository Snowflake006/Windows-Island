//! Deterministic previews for companion integration; never starts the telemetry service.
#[path="../src/bin/daozai-record/raster.rs"] mod raster;
use daozai::{app::{App,Env,Options,WIN_W,WIN_H},companion::{Agent,Snapshot,Vpn},model::{Skin,Dock}};
use eframe::egui::{self,Pos2,Rect,Vec2};
fn main(){
 let dest=std::path::PathBuf::from(std::env::args().nth(1).unwrap_or_else(||".tools/previews".into()));std::fs::create_dir_all(&dest).unwrap();
 let data=dest.join("isolated-data");std::fs::create_dir_all(&data).unwrap();std::env::set_var("DAOZAI_DATA_DIR",&data);
 for (name,skin,open,multi,side,unlock) in [
  ("compact",Skin::Classic,false,false,false,false),("vpn-yellow",Skin::Classic,false,false,false,false),("vpn-red",Skin::Classic,false,false,false,false),("cuc",Skin::Classic,false,false,false,false),("multiple",Skin::Classic,false,true,false,false),
  ("agents",Skin::Classic,true,true,false,false),("cream",Skin::Cream,true,true,false,false),
  ("glass-light",Skin::GlassLight,true,true,false,false),("glass-dark",Skin::GlassDark,true,true,false,false),
  ("cloud",Skin::Fluid,true,true,false,false),("side",Skin::Classic,false,true,true,false),
  ("unlock",Skin::Classic,false,false,false,true)] {
  let ctx=egui::Context::default();daozai::theme::load_fonts(&ctx);
  let mut app=App::new(&ctx,Options{fetch_lyrics:false,pet_idle:45.0});app.settings.skin=skin;app.settings.dock=if side{Dock::Left}else{Dock::Top};app.settings.pet=true;if name=="cuc"{app.settings.badge_style=1;}
  if open{app.show_page(6);}
  let agents=vec![Agent{name:"Codex".into(),state:"thinking".into(),window_state:Some("foreground".into()),..Default::default()},Agent{name:"WorkBuddy".into(),state:"tool".into(),..Default::default()},Agent{name:"豆包".into(),state:"action".into(),..Default::default()}];
  let mut ras=raster::Raster::new((WIN_W*2.0)as usize,(WIN_H*2.0)as usize);let mut rgba=Vec::new();
  for frame in 0..90 {
   let t=frame as f64/60.0;let env=Env{t,clock:"19:42:00".into(),today:"2026-11-12".into(),date:"11月12日 周四".into(),battery:Some(76),charging:false,
    companion:Snapshot{agents:if multi{agents.clone()}else{vec![agents[0].clone()]},vpn:Vpn{connected:true,delay:Some(if name=="vpn-yellow"{220.0}else if name=="vpn-red"{450.0}else{86.0}),text:"VPN · 86 ms".into()},ready:true,..Default::default()},unlock_version:if unlock&&frame>=30{1}else{0},..Default::default()};
   let raw=egui::RawInput{screen_rect:Some(Rect::from_min_size(Pos2::ZERO,Vec2::new(WIN_W,WIN_H))),time:Some(t),viewports:std::iter::once((egui::ViewportId::ROOT,egui::ViewportInfo{native_pixels_per_point:Some(2.0),..Default::default()})).collect(),..Default::default()};
   let output=ctx.run(raw,|ctx|{egui::CentralPanel::default().frame(egui::Frame::NONE).show(ctx,|ui|{app.frame(ui,Rect::from_min_size(Pos2::ZERO,Vec2::new(WIN_W,WIN_H)),&env);});});
   ras.update_textures(&output.textures_delta);
   if frame==89{ras.buf.fill([0.10,0.13,0.18,1.0]);ras.draw(&ctx.tessellate(output.shapes,output.pixels_per_point),output.pixels_per_point);ras.to_rgba8(&mut rgba);image::save_buffer(dest.join(format!("{name}.png")),&rgba,ras.w as u32,ras.h as u32,image::ColorType::Rgba8).unwrap();}
   ras.free_textures(&output.textures_delta);
  }
  println!("Rendered {name}");
 }
}
