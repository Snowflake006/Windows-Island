//! Local companion telemetry and presentation. No conversation content leaves this machine.
use serde::Deserialize;
use eframe::egui::{self, Color32};
use crate::{app::{App,Cmd,Env},paint::{self,Card,H},theme::{self,W}};
use std::collections::HashMap;

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default, rename_all="PascalCase")]
pub struct Agent {
    pub name:String, pub state:String, pub window_state:Option<String>,
    pub source:Option<String>, pub process_ids:Vec<u32>, pub active:usize,
    pub context:Option<serde_json::Value>, pub quota:Option<serde_json::Value>,
}
impl Agent {
    pub fn busy(&self)->bool { matches!(self.state.as_str(),"thinking"|"chat_thinking"|"tool"|"action") }
    pub fn label(&self)->&str {match self.state.as_str(){"thinking"|"chat_thinking"=>"思考中","tool"=>"执行工具","action"=>"需要操作","complete"=>"已完成","stopped"=>"已停止","error"=>"任务异常","unknown"=>"状态待确认",_=>"在线"}}
    pub fn color(&self)->Color32 {match self.state.as_str(){"chat_thinking"=>theme::BLUE,"thinking"|"tool"=>theme::YELLOW,"action"|"error"=>theme::RED_TOP,"complete"=>theme::SOFT_GREEN,_=>theme::DIM}}
}
#[derive(Clone,Debug,Default,Deserialize)]
#[serde(default,rename_all="PascalCase")]
pub struct Vpn {pub connected:bool,pub delay:Option<f64>,pub text:String}
#[derive(Clone,Debug,Default,Deserialize)]
#[serde(default,rename_all="PascalCase")]
pub struct Snapshot { pub unlock_hint:String, pub agents:Vec<Agent>,pub vpn:Vpn,pub usage:Vec<serde_json::Value>,pub ready:bool,pub sampled_at:u64 }
#[derive(Default)]
pub(crate) struct State {
    pub snapshot:Snapshot, pub visible:Vec<Agent>, previous:HashMap<String,String>,
    holds:HashMap<String,f64>, pub unlock:u64, pub unlock_at:Option<f64>,
    pub panel:bool, pub selected:Option<String>,pub first:usize,
    textures:HashMap<String,egui::TextureHandle>,
    state_at:HashMap<String,f64>,
    pub hold_seconds:f64, pub greeting_seconds:f64, pub max_icons:usize,
}
impl State {
    pub(crate) fn new()->Self{Self{panel:true,..Default::default()}}
    // Start on live state; account quota remains one click away.
    pub fn update(&mut self,snapshot:&Snapshot,t:f64,unlock:u64) {
        if unlock!=self.unlock {self.unlock=unlock;self.unlock_at=Some(t);}
        self.visible.clear();
        for a in &snapshot.agents {
            if self.previous.get(&a.name)!=Some(&a.state){self.state_at.insert(a.name.clone(),t);}
            if a.state=="complete" && self.previous.get(&a.name).is_some_and(|s|matches!(s.as_str(),"thinking"|"chat_thinking"|"tool"|"action")) {self.holds.insert(a.name.clone(),t+if self.hold_seconds>0.0{self.hold_seconds}else{3.0});}
            if a.busy(){self.holds.remove(&a.name);}
            if a.window_state.as_deref()!=Some("background")||a.busy()||self.holds.get(&a.name).is_some_and(|until|t<*until){self.visible.push(a.clone());}
            self.previous.insert(a.name.clone(),a.state.clone());
        }
        self.previous.retain(|name,_|snapshot.agents.iter().any(|a|&a.name==name));
        self.state_at.retain(|name,_|snapshot.agents.iter().any(|a|&a.name==name));
        self.holds.retain(|name,until|t<*until&&snapshot.agents.iter().any(|a|&a.name==name));
        self.snapshot=snapshot.clone();
    }
    pub fn greeting(&self,t:f64)->bool {self.unlock_at.is_some_and(|at|t-at<self.greeting_duration())}
    pub fn greeting_duration(&self)->f64{if self.greeting_seconds>0.0{self.greeting_seconds}else{3.2}}
    pub fn limit(&self)->usize{if self.max_icons>0{self.max_icons}else{4}}
}
fn badge(state:&mut State,c:&Card,x:f32,y:f32){
    // Sample the four original Windows panes supplied by the user.
    // Separate quads retain transparent gaps against every island skin.
    let key="windows-original-mark";
    if !state.textures.contains_key(key){
        if let Ok(img)=image::load_from_memory(include_bytes!("../assets/windows-mark-reference.png")){
            let rgba=img.into_rgba8();let size=[rgba.width() as usize,rgba.height() as usize];
            state.textures.insert(key.into(),c.ui.ctx().load_texture(key,egui::ColorImage::from_rgba_unmultiplied(size,rgba.as_raw()),Default::default()));
        }
    }
    if let Some(t)=state.textures.get(key){
        let size=t.size_vec2();
        for (dx,dy,sx,sy) in [(-8.0,-8.0,47.0,43.0),(0.5,-8.0,71.0,43.0),(-8.0,0.5,47.0,67.0),(0.5,0.5,71.0,67.0)]{
            let uv=egui::Rect::from_min_max(egui::pos2(sx/size.x,sy/size.y),egui::pos2((sx+20.0)/size.x,(sy+20.0)/size.y));
            c.painter.image(t.id(),c.rect(x+dx,y+dy,7.5,7.5),uv,Color32::WHITE);
        }
    }
}
fn icon(state:&mut State,c:&Card,a:&Agent,x:f32,y:f32){
    if !state.textures.contains_key(&a.name){
        let bytes:&[u8]=match a.name.as_str(){
            "Codex"|"ChatGPT"=>include_bytes!("../assets/agents/codex.png"),"Claude"=>include_bytes!("../assets/agents/claude.png"),
            "豆包"=>include_bytes!("../assets/agents/doubao-transparent.png"),"DeepSeek Harness"=>include_bytes!("../assets/agents/deepseek.png"),
            "WorkBuddy"=>include_bytes!("../assets/agents/workbuddy.png"),"Gemini"=>include_bytes!("../assets/agents/gemini.png"),
            "OpenClaw"=>include_bytes!("../assets/agents/openclaw.png"),"Ollama"=>include_bytes!("../assets/agents/ollama.png"),_=>&[],
        };
        if let Ok(img)=image::load_from_memory(bytes){let rgba=img.thumbnail(64,64).into_rgba8();let size=[rgba.width() as usize,rgba.height() as usize];let texture=c.ui.ctx().load_texture(format!("agent-{}",a.name),egui::ColorImage::from_rgba_unmultiplied(size,rgba.as_raw()),Default::default());if matches!(a.name.as_str(),"Codex"|"ChatGPT"){crate::skin_paint::mark_monochrome(texture.id());}state.textures.insert(a.name.clone(),texture);}
    }
    if let Some(texture)=state.textures.get(&a.name){if a.name=="豆包"{let mut mesh=egui::epaint::Mesh::with_texture(texture.id());mesh.vertices.push(egui::epaint::Vertex{pos:c.pos(x,y),uv:egui::pos2(0.5,0.5),color:Color32::WHITE});for i in 0..=32{let angle=i as f32/32.0*std::f32::consts::TAU;mesh.vertices.push(egui::epaint::Vertex{pos:c.pos(x+8.0*angle.cos(),y+8.0*angle.sin()),uv:egui::pos2(0.5+0.47*angle.cos(),0.5+0.47*angle.sin()),color:Color32::WHITE});if i>0{mesh.indices.extend_from_slice(&[0,i,i+1]);}}c.painter.add(egui::Shape::mesh(mesh));}else{c.painter.image(texture.id(),c.rect(x-8.0,y-8.0,16.0,16.0),egui::Rect::from_min_max(egui::Pos2::ZERO,egui::pos2(1.0,1.0)),Color32::WHITE);}}else{c.text(x,y+4.0,&a.name.chars().take(1).collect::<String>(),12.0,W::Bold,theme::GRAY,H::Center);}
    let color=c.ui.ctx().animate_value_with_time(egui::Id::new(("agent-color",&a.name)),match a.state.as_str(){"complete"=>1.0,"action"|"error"=>2.0,_=>0.0},0.24);
    let light=if color<1.0{paint::mix(a.color(),theme::SOFT_GREEN,color)}else{paint::mix(theme::SOFT_GREEN,theme::RED_TOP,color-1.0)};
    c.circle(x+7.0,y+5.0,3.4,theme::CARD); c.circle(x+7.0,y+5.0,2.1,light);
}
const AGENT_WIDTH:f32=19.0;
const AGENT_GAP:f32=crate::bar_layout::CONTENT_GAP;
fn agent_icons_width(count:usize)->f32 {if count==0{0.0}else{count as f32*AGENT_WIDTH+(count-1) as f32*AGENT_GAP}}

impl App {
    fn companion_text_width(&self,ctx:&egui::Context,text:&str,size:f32)->f32 {
        let scale=self.settings.island_scale();
        ctx.fonts(|fonts|fonts.layout_no_wrap(text.to_owned(),theme::font(size*scale,W::Regular),Color32::WHITE).size().x/scale)
    }
    fn companion_agents_width(&self,ctx:&egui::Context,shown:usize,total:usize)->f32 {
        agent_icons_width(shown)+if total>shown{AGENT_GAP+self.companion_text_width(ctx,&format!("+{}",total-shown),10.0)}else{0.0}
    }
    pub(crate) fn companion_step(&mut self,env:&Env){self.companion.hold_seconds=self.settings.companion_done_seconds as f64;self.companion.greeting_seconds=self.settings.unlock_seconds as f64+0.2;self.companion.max_icons=self.settings.companion_max_icons as usize;if !self.settings.unlock_feedback{self.companion.unlock=env.unlock_version;self.companion.unlock_at=None;}self.companion.update(&env.companion,self.t,if self.settings.unlock_feedback{env.unlock_version}else{self.companion.unlock});}
    pub(crate) fn companion_slot_enabled(&self)->bool {self.companion.greeting(self.t) || self.settings.companion_bar && (!self.companion.visible.is_empty()||self.settings.companion_todos)}
    fn companion_todo(&self)->(String,usize){
        let items:Vec<_>=self.todos.items.iter().filter(|a|a.scheduled_on(&self.today)&&!a.done_for(&self.today)).collect();
        let text=if items.is_empty(){if !self.companion.snapshot.ready{"正在连接桌面…"}else if self.todos.items.iter().any(|a|a.scheduled_on(&self.today)){"今日待办已完成"}else{"今日暂无待办"}.to_owned()}else{items[(self.t/6.0) as usize%items.len()].text.clone()};
        (text,items.len())
    }
    pub(crate) fn companion_width(&self,ctx:&egui::Context)->f32 {
        if !self.companion_slot_enabled(){return 0.0;}
        if self.companion.greeting(self.t){
            let scale=self.settings.island_scale();
            let label=ctx.fonts(|fonts|fonts.layout_no_wrap("已解锁".into(),theme::font(11.0*scale,W::Semibold),Color32::WHITE).size().x/scale);
            return label+if self.companion.snapshot.unlock_hint=="face"{24.0+AGENT_GAP}else{0.0};
        }
        match self.companion.visible.as_slice(){
            []=>self.companion_text_width(ctx,&self.companion_todo().0,10.5).min(116.0),
            [agent]=>AGENT_WIDTH+if self.settings.companion_labels{AGENT_GAP+self.companion_text_width(ctx,agent.label(),10.5)}else{0.0},
            agents=>self.companion_agents_width(ctx,agents.len().min(self.companion.limit()),agents.len()),
        }
    }
    pub(crate) fn companion_badge_draw(&mut self,c:&Card,x:f32,y:f32){
        if self.settings.badge_style==1 {
            let key="cuc-emblem";
            if !self.companion.textures.contains_key(key){
                if let Ok(img)=image::load_from_memory(include_bytes!("../assets/cuc-emblem.png")){
                    let rgba=img.thumbnail(128,128).into_rgba8();let size=[rgba.width() as usize,rgba.height() as usize];
                    self.companion.textures.insert(key.into(),c.ui.ctx().load_texture(key,egui::ColorImage::from_rgba_unmultiplied(size,rgba.as_raw()),Default::default()));
                }
            }
            if let Some(t)=self.companion.textures.get(key){
                let mut mesh=egui::epaint::Mesh::with_texture(t.id());mesh.vertices.push(egui::epaint::Vertex{pos:c.pos(x,y),uv:egui::pos2(0.5,0.5),color:Color32::WHITE});
                for i in 0..=64{let angle=i as f32/64.0*std::f32::consts::TAU;mesh.vertices.push(egui::epaint::Vertex{pos:c.pos(x+11.0*angle.cos(),y+11.0*angle.sin()),uv:egui::pos2(0.5+0.5*angle.cos(),0.5+0.5*angle.sin()),color:Color32::WHITE});if i>0{mesh.indices.extend_from_slice(&[0,i,i+1]);}}
                c.painter.add(egui::Shape::mesh(mesh));
            }
        }else{badge(&mut self.companion,c,x,y);}
        if c.hit(x-12.0,y-12.0,24.0,24.0,"companion-mark").on_hover_text("智能体与连接状态").clicked(){self.companion.panel=true;self.show_page(6);}
    }

    pub(crate) fn vpn_clock(&self,c:&Card,x:f32,y:f32,w:f32,h:f32){
        if !self.settings.vpn_clock{return;}
        let vpn=&self.companion.snapshot.vpn;
        let target=if !vpn.connected{0.0}else{match vpn.delay{Some(d) if d<=150.0=>1.0,Some(d) if d<=300.0=>2.0,_=>3.0}};
        let k=c.ui.ctx().animate_value_with_time(egui::Id::new("vpn-clock"),target,0.62);
        // Match the reference: a solid, bright time capsule with no separate indicator dot.
        let blue=Color32::from_rgb(0,145,255);let amber=Color32::from_rgb(255,159,10);let red=Color32::from_rgb(255,69,58);
        let color=if k<1.0{blue}else if k<2.0{paint::mix(blue,amber,k-1.0)}else{paint::mix(amber,red,k-2.0)};
        if k>0.01 && self.settings.vpn_tint {
            c.faded(k.min(1.0)).fill(x-6.0,y,w+12.0,h,h/2.0,color);
        }
        c.hit(x-6.0,y,w+12.0,h,"vpn-clock-tip").on_hover_text(if vpn.text.is_empty(){"VPN 未连接"}else{&vpn.text});
    }
    pub(crate) fn companion_bar(&mut self,c:&Card,cx:f32,width:f32){
        let x=cx-width/2.0;
        let clip=c.clipped(x,0.0,width,30.0);let c=&clip;

        if !self.settings.companion_bar&&!self.companion.greeting(self.t){return;}
        if self.companion.visible.is_empty()&&!self.settings.companion_todos&&!self.companion.greeting(self.t){return;}
        if width<16.0{return;}
        if self.companion.greeting(self.t){
            let age=(self.t-self.companion.unlock_at.unwrap()) as f32;
            let a=(age/0.24).min(1.0)*((self.companion.greeting_duration() as f32-age)/0.35).min(1.0);let cc=c.faded(a);
            // A small smile grows into the island, sharing its easing and blue accent.
            let frame=((age/0.05) as usize).min(13);
            let key=format!("hello-{frame}");
            if self.companion.snapshot.unlock_hint=="face" && !self.companion.textures.contains_key(&key){
                if let Ok(img)=image::open(crate::model::config_dir().join("companion").join(format!("{key}.png"))){let rgba=img.into_rgba8();let size=[rgba.width() as usize,rgba.height() as usize];self.companion.textures.insert(key.clone(),c.ui.ctx().load_texture(&key,egui::ColorImage::from_rgba_unmultiplied(size,rgba.as_raw()),Default::default()));}
            }
            if let Some(texture)=self.companion.textures.get(&key).filter(|_|self.companion.snapshot.unlock_hint=="face"){
                cc.painter.image(texture.id(),cc.rect(x,3.0,24.0,24.0),egui::Rect::from_min_max(egui::Pos2::ZERO,egui::pos2(1.0,1.0)),Color32::WHITE);
                cc.text(x+24.0+AGENT_GAP,19.0,"已解锁",11.0,W::Semibold,theme::WHITE,H::Left);return;
            }
            if self.companion.snapshot.unlock_hint!="face" {cc.text(x,19.0,"已解锁",11.0,W::Semibold,theme::WHITE,H::Left);return;}
            let xx=x+12.0;let yy=15.0;let k=0.82+0.18*crate::anim::smoothstep(0.0,0.5,age);
            let cc=cc.scaled(xx,yy,k);cc.circle(xx-4.0,yy-3.0,1.2,theme::BLUE);cc.circle(xx+4.0,yy-3.0,1.2,theme::BLUE);
            let points=(0..=16).map(|i|{let u=i as f32/16.0;cc.pos(xx-6.0+12.0*u,yy+2.0+3.5*(u*std::f32::consts::PI).sin())}).collect();
            cc.painter.add(egui::Shape::line(points,egui::Stroke::new(1.4*cc.s,theme::BLUE)));
            cc.text(x+24.0+AGENT_GAP,19.0,"已解锁",11.0,W::Semibold,theme::WHITE,H::Left);return;
        }
        let agents=self.companion.visible.clone();
        if agents.is_empty(){
            let (text,count)=self.companion_todo();
            let fade=if count>1{crate::anim::smoothstep(0.0,0.24,(self.t%6.0) as f32)}else{1.0};
            c.faded(fade).shifted(0.0,(1.0-fade)*2.0).text(x,19.0,&c.fit(&text,10.5,W::Regular,width),10.5,W::Regular,theme::GRAY,H::Left);
            if c.hit(x,2.0,width,27.0,"companion-todo").on_hover_text(text).clicked(){self.show_page(4);}return;
        }
        let mut capacity=agents.len().min(self.companion.limit());
        while capacity>1 && self.companion_agents_width(c.ui.ctx(),capacity,agents.len())>width+0.1{capacity-=1;}
        for (i,a) in agents.iter().take(capacity).enumerate(){
            let target=x+8.0+i as f32*(AGENT_WIDTH+AGENT_GAP);
            let xx=target; // Parent layout owns movement; preview and island never share absolute coordinates.
            let age=(self.t-self.companion.state_at.get(&a.name).copied().unwrap_or(0.0)) as f32;
            let fade=crate::anim::smoothstep(0.0,0.2,age);
            let shifted=c.shifted(0.0,(1.0-fade)*2.0).faded(fade);
            icon(&mut self.companion,&shifted,a,xx,15.0);
            let w=if agents.len()==1{width}else{AGENT_WIDTH};
            let hit=c.hit(xx-8.0,2.0,w,27.0,("live-agent",&a.name));
            if hit.on_hover_text(format!("{} · {}",a.name,a.label())).clicked(){self.companion.panel=true;self.companion.selected=Some(a.name.clone());self.show_page(6);}
            if agents.len()==1 && width>=AGENT_WIDTH+AGENT_GAP+10.5 && self.settings.companion_labels{shifted.text(x+AGENT_WIDTH+AGENT_GAP,19.0,&shifted.fit(a.label(),10.5,W::Regular,(width-AGENT_WIDTH-AGENT_GAP).max(0.0)),10.5,W::Regular,a.color(),H::Left);}
        }
        if agents.len()>capacity {
            let more=format!("+{}",agents.len()-capacity);
            let left=x+agent_icons_width(capacity)+AGENT_GAP;
            if left+c.text_w(&more,10.0,W::Regular)<=x+width+0.1 {
                c.text(left,19.0,&more,10.0,W::Regular,theme::GRAY,H::Left);
                if c.hit(left,2.0,width-(left-x),27.0,"live-agent-more").on_hover_text("查看所有智能体").clicked(){self.companion.panel=true;self.show_page(6);}
            }
        }
    }
    pub(crate) fn companion_side(&mut self,c:&Card,cx:f32,top:f32){
        if self.settings.companion_badge{self.companion_badge_draw(c,cx,top+12.0);}
        if c.hit(cx-12.0,top,24.0,24.0,"side-companion").on_hover_text("智能体与连接状态").clicked(){self.companion.panel=true;self.show_page(6);}
        let agents=self.companion.visible.clone();
        if self.companion.greeting(self.t){c.text(cx,top+33.0,"已解锁",8.5,W::Regular,theme::BLUE,H::Center);return;}
        for(i,a)in agents.iter().take(if self.settings.companion_bar{self.companion.limit()}else{0}).enumerate(){let y=top+if self.settings.companion_badge{36.0}else{12.0}+i as f32*24.0;icon(&mut self.companion,c,a,cx,y);if c.hit(cx-12.0,y-12.0,24.0,24.0,("side-live",&a.name)).on_hover_text(format!("{} · {}",a.name,a.label())).clicked(){self.companion.panel=true;self.companion.selected=Some(a.name.clone());self.show_page(6);}}
    }
    pub(crate) fn page_companion(&mut self,c:&Card,cmds:&mut Vec<Cmd>){
        for (x,label,on) in [(44.0,"运行状态",self.companion.panel),(135.0,"账户额度",!self.companion.panel)]{
            let (r,b)=paint::capsule(c,x,30.0,82.0,22.0,label,if on{theme::BTN_HOVER}else{theme::CARD},theme::BTN_HOVER);
            b.text(x+41.0,45.0,label,10.5,W::Semibold,if on{theme::WHITE}else{theme::GRAY},H::Center);
            if r.clicked(){self.companion.panel=label=="运行状态";self.companion.selected=None;}
        }
        if !self.companion.panel {self.page_quota(&c.shifted(0.0,27.0));return;}
        let vpn=self.companion.snapshot.vpn.clone();
        c.circle(255.0,41.0,2.5,if vpn.connected{theme::SOFT_GREEN}else{theme::DIM});
        c.text(264.0,45.0,&c.fit(&vpn.text,9.5,W::Regular,103.0),9.5,W::Regular,theme::GRAY,H::Left);
        if let Some(name)=self.companion.selected.clone(){
            if c.hit(44.0,60.0,50.0,20.0,"agent-back").on_hover_text("返回列表").clicked(){self.companion.selected=None;return;}
            c.text(44.0,75.0,"‹ 返回",10.5,W::Regular,theme::GRAY,H::Left);
            if let Some(a)=self.companion.snapshot.agents.iter().find(|a|a.name==name).cloned(){
                icon(&mut self.companion,c,&a,120.0,69.0);c.text(136.0,74.0,&format!("{} · {}",a.name,a.label()),12.0,W::Semibold,theme::WHITE,H::Left);
                let source=a.source.as_deref().unwrap_or("本机进程；没有可确认的任务事件");
                c.text(44.0,99.0,&c.fit(source,10.0,W::Regular,320.0),10.0,W::Regular,theme::GRAY,H::Left);
                let usage:Vec<_>=self.companion.snapshot.usage.iter().filter(|u|u["Agent"].as_str()==Some(a.name.as_str())).collect();
                let sum=|key:&str|usage.iter().filter_map(|u|u[key].as_u64()).sum::<u64>();
                let tokens=if usage.is_empty(){"暂无 Token 用量记录".into()}else{format!("输入 {}（含缓存 {}） · 输出 {}",sum("Input"),sum("Cached"),sum("Output"))};
                c.text(44.0,118.0,&c.fit(&tokens,10.0,W::Regular,320.0),10.0,W::Regular,theme::GRAY,H::Left);
                let context=a.context.as_ref();let used=context.and_then(|v|v["Tokens"].as_f64());let window=context.and_then(|v|v["Window"].as_f64()).filter(|v|*v>0.0);
                let context_text=match(used,window){(Some(n),Some(w))=>format!("上下文 {:.0}% · {:.0} / {:.0}",100.0*n/w,n,w),(Some(n),None)=>format!("本轮输入 {:.0} tokens · 窗口未知",n),_=>"暂无上下文快照".into()};
                c.text(44.0,139.0,&context_text,10.0,W::Regular,theme::GRAY,H::Left);
                if let(Some(n),Some(w))=(used,window){let k=(n/w).clamp(0.0,1.0) as f32;let color=if k>=0.9{theme::RED_TOP}else if k>=0.75{theme::YELLOW}else{theme::BLUE};c.fill(44.0,147.0,323.0,3.0,1.5,theme::TRACK);c.fill(44.0,147.0,323.0*k,3.0,1.5,color);}
                let used=a.quota.as_ref().and_then(|q|q["primary"]["used_percent"].as_f64());
                let quota=used.map(|n|format!("额度剩余 {:.0}%",(100.0-n).clamp(0.0,100.0))).unwrap_or_else(||"未提供额度快照".into());
                c.text(44.0,174.0,&quota,10.0,W::Regular,theme::DIM,H::Left);
                c.hit(44.0,155.0,220.0,24.0,"agent-quota-tip").on_hover_text("用量来自已读取的本机会话，缓存包含在输入总量中；账户完整额度请切换到账户额度。");
                let (r,b)=paint::capsule(c,285.0,158.0,82.0,23.0,"agent-open",theme::BTN,theme::BTN_HOVER);b.text(326.0,174.0,"打开应用",10.5,W::Regular,theme::WHITE,H::Center);
                if r.clicked(){cmds.push(Cmd::AgentWindow(a.process_ids));}
            }else{c.text(44.0,100.0,"应用已退出",12.0,W::Regular,theme::GRAY,H::Left);}return;
        }
        let agents=self.companion.snapshot.agents.clone();let total=agents.len();self.companion.first=self.companion.first.min(total.saturating_sub(3));
        if total==0 {c.text(209.0,101.0,if self.companion.snapshot.ready{"桌面已就绪"}else{"正在读取本机状态…"},14.0,W::Semibold,theme::WHITE,H::Center);c.text(209.0,126.0,"打开智能体后，工作状态会自动出现在这里",10.5,W::Regular,theme::GRAY,H::Center);}
        for (i,a) in agents.iter().skip(self.companion.first).take(3).enumerate(){
            let y=62.0+i as f32*32.0;c.fill(44.0,y,323.0,28.0,8.0,theme::CARD);icon(&mut self.companion,c,a,60.0,y+14.0);
            c.text(77.0,y+18.0,&a.name,11.0,W::Semibold,theme::WHITE,H::Left);c.text(352.0,y+18.0,a.label(),10.5,W::Regular,a.color(),H::Right);
            if c.hit(44.0,y,323.0,28.0,("agent-row",&a.name)).clicked(){self.companion.selected=Some(a.name.clone());}
        }
        if total>0{let busy=agents.iter().filter(|a|matches!(a.state.as_str(),"thinking"|"chat_thinking"|"tool")).count();let attention=agents.iter().filter(|a|matches!(a.state.as_str(),"action"|"error")).count();c.text(44.0,177.0,&format!("{total} 个智能体 · {busy} 运行中 · {attention} 需关注"),9.5,W::Regular,theme::DIM,H::Left);}
        if total>3{for(x,delta,label)in[(290.0,-3isize,"‹"),(335.0,3,"›")]{if c.hit(x,161.0,27.0,20.0,("agent-scroll",delta)).clicked(){self.companion.first=self.companion.first.saturating_add_signed(delta).min(total.saturating_sub(3));}c.text(x+10.0,176.0,label,14.0,W::Regular,theme::GRAY,H::Center);}}
    }
}

/// The helper is owned by Daozai, bundled in the executable, and stopped on exit.
#[cfg(windows)]
pub struct Service {child:Option<std::process::Child>,rx:std::sync::mpsc::Receiver<Snapshot>,pub latest:Snapshot,ctx:egui::Context,retry_at:std::time::Instant}
#[cfg(windows)]
impl Service {
    pub fn start(ctx:egui::Context)->Self {
        use std::{io::{BufRead,BufReader},os::windows::process::CommandExt};
        let (tx,rx)=std::sync::mpsc::sync_channel(2);let root=crate::model::config_dir().join("companion-runtime");let data=crate::model::config_dir().join("companion");
        let files=[("Hello.ps1",include_str!("companion/Hello.ps1")),("Bridge.ps1",include_str!("companion/Bridge.ps1")),("Collector.ps1",include_str!("companion/Collector.ps1")),("AgentStatus.ps1",include_str!("companion/AgentStatus.ps1")),("AgentProcesses.ps1",include_str!("companion/AgentProcesses.ps1")),("AgentTelemetry.py",include_str!("companion/AgentTelemetry.py")),("DesktopAgentStatus.cs",include_str!("companion/DesktopAgentStatus.cs")),("DesktopAgentMonitor.ps1",include_str!("companion/DesktopAgentMonitor.ps1")),("RuntimePaths.ps1",include_str!("companion/RuntimePaths.ps1")),("VpnStatus.ps1",include_str!("companion/VpnStatus.ps1"))];
        let setup=(||->std::io::Result<()>{std::fs::create_dir_all(&root)?;std::fs::create_dir_all(&data)?;if !root.join("python-runtime.zip").exists(){std::fs::write(root.join("python-runtime.zip"),include_bytes!("../assets/runtime/python-3.14.10-embed-amd64.zip"))?;}for(name,content)in files{std::fs::write(root.join(name),format!("\u{feff}{}",content.trim_start_matches('\u{feff}')))?;}Ok(())})();
        let mut child=if setup.is_ok(){std::process::Command::new("powershell.exe").args(["-NoProfile","-ExecutionPolicy","Bypass","-File"]).arg(root.join("Bridge.ps1")).arg("-Owner").arg(std::process::id().to_string()).env("WORKPELLET_DATA_DIR",&data).creation_flags(0x08000000).stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::null()).spawn().ok()}else{None};
        let wake=ctx.clone();
        if let Some(stdout)=child.as_mut().and_then(|p|p.stdout.take()){std::thread::spawn(move||{for line in BufReader::new(stdout).lines().map_while(Result::ok){if let Ok(snapshot)=serde_json::from_str::<Snapshot>(&line){match tx.try_send(snapshot){Err(std::sync::mpsc::TrySendError::Disconnected(_))=>break,_=>{}}wake.request_repaint();}}});}
        Self{child,rx,latest:Snapshot::default(),ctx,retry_at:std::time::Instant::now()+std::time::Duration::from_secs(5)}
    }
    pub fn snapshot(&mut self)->Snapshot{if std::time::Instant::now()>=self.retry_at && self.child.as_mut().map_or(true,|p|p.try_wait().ok().flatten().is_some()) {*self=Self::start(self.ctx.clone());}while let Ok(s)=self.rx.try_recv(){self.latest=s;}let now=std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs();if self.latest.sampled_at>0&&now.saturating_sub(self.latest.sampled_at)>15{self.latest.agents.clear();self.latest.ready=false;self.latest.vpn=Vpn{text:"连接状态暂不可读".into(),..Default::default()};}self.latest.clone()}
}
#[cfg(windows)]
impl Drop for Service{fn drop(&mut self){if let Some(p)=self.child.as_mut(){if p.try_wait().ok().flatten().is_some(){return;}
    use std::os::windows::process::CommandExt;
    let _=std::process::Command::new("taskkill.exe").args(["/PID",&p.id().to_string(),"/T","/F"]).creation_flags(0x08000000).output();let _=p.wait();
}}}
#[cfg(test)]
mod tests {
    use super::*;
    fn agent(state:&str)->Agent{Agent{name:"Codex".into(),state:state.into(),window_state:Some("background".into()),..Default::default()}}
    #[test] fn background_completion_has_one_hold_and_new_work_cancels_it(){
        let mut s=State::default(); let snapshot=|state|Snapshot{agents:vec![agent(state)],ready:true,..Default::default()};
        s.update(&snapshot("thinking"),0.0,0);assert_eq!(s.visible.len(),1);
        s.update(&snapshot("complete"),1.0,0);assert_eq!(s.visible.len(),1);
        s.update(&snapshot("complete"),3.8,0);assert_eq!(s.visible.len(),1);
        s.update(&snapshot("complete"),4.1,0);assert!(s.visible.is_empty());
        s.update(&snapshot("thinking"),5.0,0);assert_eq!(s.visible.len(),1);
        s.update(&snapshot("complete"),6.0,0);s.update(&snapshot("tool"),6.1,0);assert!(s.holds.is_empty());
    }
    #[test] fn missing_metadata_never_becomes_completed(){let mut s=State::default();s.update(&Snapshot{agents:vec![agent("unknown")],..Default::default()},0.0,0);assert!(s.visible.is_empty());assert!(s.holds.is_empty());}
    #[test] fn unlock_is_an_event_not_a_repeated_snapshot(){let mut s=State::default();s.update(&Snapshot::default(),1.0,1);assert!(s.greeting(2.0));s.update(&Snapshot::default(),5.0,1);assert!(!s.greeting(5.0));}
    #[test] fn parses_powershell_snapshot(){let s:Snapshot=serde_json::from_str(r#"{"Agents":[{"Name":"Codex","State":"tool","ProcessIds":[123],"WindowState":"background"}],"Vpn":{"Connected":true,"Delay":42,"Text":"42 ms"},"Ready":true}"#).unwrap();assert!(s.agents[0].busy());assert_eq!(s.vpn.delay,Some(42.0));}
}
