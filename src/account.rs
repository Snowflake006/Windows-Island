//! User-authorized settings backup. Tokens live only in Windows Credential Manager.
use crate::{app::App, extras::{settings_card, settings_hint, settings_label}, model::{self, Settings}};
use eframe::egui;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{collections::BTreeMap, sync::mpsc::{self, Receiver}, time::Duration};

const FILE: &str = "windows-island-settings-v1.json";
const DESCRIPTION: &str = "Windows Island settings backup";
const LIMIT: u64 = 256 * 1024;

#[derive(Clone, Default, Serialize, Deserialize)]
struct Profile {
    login: String,
    id: u64,
    #[serde(default)]
    synced: String,
}

#[derive(Serialize, Deserialize)]
struct Backup {
    app: String,
    version: u32,
    owner: u64,
    saved_at: String,
    settings: BTreeMap<String, String>,
}

// Only general preferences are portable. Machine identifiers, app paths and
// ignored calendar/mail items are deliberately excluded along with all secrets.
fn portable_key(key: &str) -> bool {
    matches!(key, "skin" | "island_shape" | "dock" | "glass_blur" | "island_size"
        | "settings_theme" | "pet" | "minimal" | "browser_minimal" | "avoid_browsers"
        | "visible_pages" | "page_order" | "resident_order" | "clock_period"
        | "badge_style" | "companion_badge" | "companion_labels" | "companion_todos"
        | "vpn_tint" | "companion_max_icons" | "companion_done_seconds" | "unlock_seconds"
        | "companion_bar" | "vpn_clock" | "unlock_feedback" | "clock_12h" | "show_battery"
        | "notifications" | "sound" | "lyrics_enabled" | "island_lyrics" | "lyric_delay_ms"
        | "hide_fullscreen" | "focus_minutes" | "rest_minutes" | "water_minutes"
        | "serving_ml" | "water_start" | "water_end")
}

fn make_backup(settings: &Settings, owner: u64) -> Backup {
    Backup { app: "windows-island".into(), version: 1, owner,
        saved_at: chrono::Utc::now().to_rfc3339(),
        settings: settings.pairs().into_iter().filter(|(k,_)|portable_key(k)).collect() }
}

fn restore(current: &Settings, raw: &str, owner: u64) -> Result<Settings,String> {
    if raw.len() as u64 > LIMIT { return Err("备份文件过大，未恢复".into()); }
    let backup: Backup = serde_json::from_str(raw).map_err(|_|"备份格式不正确")?;
    if backup.app != "windows-island" || backup.version != 1 || backup.owner != owner || backup.settings.is_empty() {
        return Err("备份版本或所属账户不匹配，未恢复".into());
    }
    if backup.settings.iter().any(|(k,v)|!portable_key(k) || v.contains(['\r','\n']) || v.len()>4096) {
        return Err("备份包含不支持的设置，未恢复".into());
    }
    let mut pairs: BTreeMap<_,_> = current.pairs().into_iter().collect();
    pairs.extend(backup.settings);
    Ok(Settings::from_pairs(pairs.into_iter().collect()))
}

enum Action { Connect(String), Upload(String), Download }
struct Outcome { profile: Profile, restored: Option<String>, message: String }

#[derive(Default)]
pub(crate) struct AccountState {
    profile: Option<Profile>,
    token: String,
    note: String,
    receiver: Option<Receiver<Result<Outcome,String>>>,
    pending_restore: Option<String>,
    confirm_disconnect: bool,
}

impl AccountState {
    pub(crate) fn load() -> Self {
        let path=model::config_dir().join("account.json");
        let profile=std::fs::read(path).ok().and_then(|b|serde_json::from_slice::<Profile>(&b).ok())
            .filter(|p|p.id>0 && !p.login.is_empty());
        Self { profile, ..Default::default() }
    }

    fn start(&mut self, action: Action, ctx: &egui::Context) {
        if self.receiver.is_some(){return;}
        let profile=self.profile.clone();
        let (tx,rx)=mpsc::channel();self.receiver=Some(rx);
        self.note="正在连接 GitHub…".into();
        let ctx=ctx.clone();
        std::thread::spawn(move||{let result=perform(action,profile);let _=tx.send(result);ctx.request_repaint();});
    }

    pub(crate) fn poll(&mut self) {
        let Some(rx)=self.receiver.as_ref() else{return;};
        let result=match rx.try_recv(){Ok(r)=>r,Err(mpsc::TryRecvError::Empty)=>return,
            Err(_)=>Err("连接任务意外结束，请重试".into())};
        self.receiver=None;
        match result {
            Ok(out)=>{
                let save=(||->Result<(),String>{
                    std::fs::create_dir_all(model::config_dir()).map_err(|_|"无法创建账户目录")?;
                    let raw=serde_json::to_vec_pretty(&out.profile).map_err(|_|"无法保存账户")?;
                    model::atomic_write(&model::config_dir().join("account.json"),&raw).map_err(|_|"账户信息保存失败".to_string())
                })();
                self.profile=Some(out.profile);self.pending_restore=out.restored;self.note=out.message;
                if let Err(e)=save{self.note=format!("{}；{e}，重启后需重新连接",self.note);}
            }
            Err(e)=>self.note=e,
        }
    }
}

#[cfg(windows)]
fn credential(id:u64)->Result<keyring::Entry,String>{
    keyring::Entry::new("WindowsIsland.Account.GitHub",&id.to_string()).map_err(|_|"Windows 凭据管理器不可用".into())
}
#[cfg(windows)]
fn load_token(id:u64)->Result<String,String>{credential(id)?.get_password().map_err(|_|"登录凭据不可用，请断开后重新连接 GitHub".into())}
#[cfg(windows)]
fn save_token(id:u64,token:&str)->Result<(),String>{credential(id)?.set_password(token).map_err(|_|"无法安全保存登录凭据，连接未完成".into())}
#[cfg(windows)]
fn delete_token(id:u64)->Result<(),String>{
    match credential(id)?.delete_credential(){Ok(())|Err(keyring::Error::NoEntry)=>Ok(()),Err(_)=>Err("无法删除登录凭据，请重试".into())}
}
#[cfg(not(windows))]
fn load_token(_:u64)->Result<String,String>{Err("账户连接仅支持 Windows".into())}
#[cfg(not(windows))]
fn save_token(_:u64,_:&str)->Result<(),String>{Err("账户连接仅支持 Windows".into())}
#[cfg(not(windows))]
fn delete_token(_:u64)->Result<(),String>{Ok(())}

fn api(method:&str,path:&str,token:&str,body:Option<Value>)->Result<Value,String>{
    // Never follow a redirect with a bearer token, and never surface raw HTTP errors.
    let agent=ureq::AgentBuilder::new().timeout(Duration::from_secs(25)).redirects(0).build();
    let request=agent.request(method,&format!("https://api.github.com{path}"))
        .set("User-Agent","Windows-Island/1.0")
        .set("Accept","application/vnd.github+json")
        .set("Authorization",&format!("Bearer {token}"));
    let response=match body {Some(body)=>request.set("Content-Type","application/json").send_string(&body.to_string()),None=>request.call()};
    let response=response.map_err(|e|match e {
        ureq::Error::Status(401,_)=>"GitHub 凭据无效或已过期，请重新连接".to_string(),
        ureq::Error::Status(403,_)=>"GitHub 拒绝访问，请检查 Gists 读写权限或稍后重试".into(),
        ureq::Error::Status(404,_)=>"GitHub 备份不存在或无权访问".into(),
        _=>"GitHub 请求失败，请检查网络后重试".into(),
    })?;
    use std::io::Read;
    let mut raw=Vec::new();response.into_reader().take(4*1024*1024+1).read_to_end(&mut raw).map_err(|_|"读取 GitHub 响应失败")?;
    if raw.len()>4*1024*1024{return Err("GitHub 响应过大".into());}
    serde_json::from_slice(&raw).map_err(|_|"GitHub 返回格式错误".into())
}

fn identity(token:&str)->Result<Profile,String>{
    let user=api("GET","/user",token,None)?;
    let id=user["id"].as_u64().filter(|id|*id>0).ok_or("GitHub 账户信息不完整")?;
    let login=user["login"].as_str().filter(|s|!s.is_empty()).ok_or("GitHub 账户信息不完整")?.to_string();
    Ok(Profile{login,id,..Default::default()})
}

fn find_gist(token:&str,owner:u64)->Result<Option<String>,String>{
    for page in 1..=20 {
        let list=api("GET",&format!("/gists?per_page=100&page={page}"),token,None)?;
        let entries=list.as_array().ok_or("GitHub 备份列表格式错误")?;
        for gist in entries {
            if gist["owner"]["id"].as_u64()==Some(owner) && gist["public"]==false
                && gist["description"]==DESCRIPTION && gist["files"].get(FILE).is_some() {
                let id=gist["id"].as_str().filter(|s|!s.is_empty() && s.bytes().all(|c|c.is_ascii_hexdigit())).ok_or("备份标识无效")?;
                return Ok(Some(id.to_string()));
            }
        }
        if entries.len()<100{return Ok(None);}
    }
    Err("Gist 数量过多，未自动定位备份".into())
}

fn checked_content(gist:&Value,owner:u64)->Result<&str,String>{
    if gist["owner"]["id"].as_u64()!=Some(owner) || gist["public"]!=false || gist["description"]!=DESCRIPTION {
        return Err("备份归属或可见性不正确，操作已取消".into());
    }
    let file=&gist["files"][FILE];
    if file["truncated"]==true || file["size"].as_u64().unwrap_or(LIMIT+1)>LIMIT {
        return Err("备份文件过大或不完整".into());
    }
    file["content"].as_str().ok_or("备份内容缺失".into())
}

fn perform(action:Action,profile:Option<Profile>)->Result<Outcome,String>{
    let connecting=matches!(action,Action::Connect(_));
    let token=match &action {Action::Connect(t)=>t.trim().to_string(),_=>load_token(profile.as_ref().ok_or("请先连接 GitHub")?.id)?};
    if token.is_empty() || token.contains(['\r','\n']){return Err("请填写有效的 GitHub 访问令牌".into());}
    let mut user=identity(&token)?;
    if !connecting && profile.as_ref().map(|p|p.id)!=Some(user.id){return Err("登录账户发生变化，请重新连接".into());}
    if let Some(old)=&profile{if old.id==user.id{user.synced=old.synced.clone();}}
    let gist=find_gist(&token,user.id)?;
    let mut restored=None;
    let message=match action {
        Action::Connect(_)=>{save_token(user.id,&token)?;if gist.is_some(){"GitHub 已连接，发现已有备份，可手动恢复"}else{"GitHub 已连接，可保存第一份设置备份"}.into()},
        Action::Upload(content)=>{
            if let Some(id)=&gist {
                let existing=api("GET",&format!("/gists/{id}"),&token,None)?;
                checked_content(&existing,user.id)?;
            }
            let body=json!({"description":DESCRIPTION,"public":false,"files":{(FILE):{"content":content}}});
            let (method,path)=match gist{Some(id)=>("PATCH",format!("/gists/{id}")),None=>("POST","/gists".into())};
            let saved=api(method,&path,&token,Some(body))?;checked_content(&saved,user.id)?;
            user.synced=chrono::Local::now().format("%Y-%m-%d %H:%M").to_string();
            "设置已备份到 GitHub".into()
        }
        Action::Download=>{
            let id=gist.ok_or("此 GitHub 账户还没有设置备份")?;
            let value=api("GET",&format!("/gists/{id}"),&token,None)?;
            let content=checked_content(&value,user.id)?;
            restore(&Settings::default(),content,user.id)?;
            restored=Some(content.to_string());"备份已下载，请确认后恢复".into()
        }
    };
    Ok(Outcome{profile:user,restored,message})
}

impl App {
    pub fn open_account_settings(&mut self){self.settings_tab=12;self.open_settings();}

    pub(crate) fn account_settings(&mut self,ui:&mut egui::Ui){
        self.account.poll();
        let busy=self.account.receiver.is_some();
        if busy{ui.ctx().request_repaint_after(Duration::from_millis(200));}
        settings_hint(ui,"连接账户，为你的 Windows Island 保存和恢复个人偏好。");
        settings_label(ui,"GitHub");
        settings_card(ui,|ui|{
            if let Some(profile)=self.account.profile.clone(){
                ui.label(egui::RichText::new(format!("已连接 · @{}",profile.login)).strong());
                let sync_note=if profile.synced.is_empty(){"尚未在此设备保存云端备份".into()}else{format!("上次备份：{}",profile.synced)};
                settings_hint(ui,&sync_note);
                ui.add_space(5.0);
                ui.add_enabled_ui(!busy && self.account.pending_restore.is_none() && !self.account.confirm_disconnect,|ui|{ui.horizontal_wrapped(|ui|{
                    if ui.button("备份当前设置").clicked(){
                        match serde_json::to_string(&make_backup(&self.settings,profile.id)){
                            Ok(body)=>self.account.start(Action::Upload(body),ui.ctx()),
                            Err(_)=>self.account.note="无法生成设置备份".into(),
                        }
                    }
                    if ui.button("恢复云端设置").clicked(){self.account.start(Action::Download,ui.ctx());}
                    if ui.button("断开连接").clicked(){self.account.confirm_disconnect=true;}
                });});
                if self.account.confirm_disconnect{
                    settings_hint(ui,"断开后保留本机设置与云端备份，只删除此设备的登录凭据。");
                    ui.horizontal(|ui|{
                        if ui.button("确认断开").clicked(){
                            let result=delete_token(profile.id).and_then(|_|{
                                match std::fs::remove_file(model::config_dir().join("account.json")){
                                    Ok(())=>Ok(()),Err(e) if e.kind()==std::io::ErrorKind::NotFound=>Ok(()),Err(_)=>Err("删除账户信息失败，请重试".into())
                                }
                            });
                            match result{Ok(())=>{self.account=AccountState::default();self.account.note="已断开 GitHub，设置和云端备份已保留".into();},Err(e)=>self.account.note=e}
                        }
                        if ui.button("取消").clicked(){self.account.confirm_disconnect=false;}
                    });
                }
            }else{
                ui.label(egui::RichText::new("连接 GitHub 账户").strong());
                settings_hint(ui,"使用个人访问令牌连接，需授予 Gists 读写权限（经典令牌勾选 gist）。");
                ui.hyperlink_to("在 GitHub 创建访问令牌 ↗","https://github.com/settings/tokens/new?scopes=gist&description=Windows%20Island%20Settings");
                ui.add(egui::TextEdit::singleline(&mut self.account.token).password(true).hint_text("粘贴 GitHub 访问令牌").desired_width(f32::INFINITY));
                if ui.add_enabled(!busy && !self.account.token.trim().is_empty(),egui::Button::new("连接 GitHub")).clicked(){
                    let token=std::mem::take(&mut self.account.token);self.account.start(Action::Connect(token),ui.ctx());
                }
            }
        });
        if busy{ui.horizontal(|ui|{ui.spinner();ui.label("正在处理，请稍候…");});}
        if !self.account.note.is_empty(){ui.label(&self.account.note);}
        if let Some(raw)=self.account.pending_restore.clone(){
            settings_card(ui,|ui|{
                ui.label(egui::RichText::new("恢复云端偏好？").strong());
                if let Ok(backup)=serde_json::from_str::<Backup>(&raw){settings_hint(ui,&format!("备份时间：{}",backup.saved_at));}
                settings_hint(ui,"将替换外观、页面布局、专注和饮水偏好。本次设置会先保存在本地恢复副本中。");
                ui.horizontal(|ui|{
                    if ui.button("确认恢复").clicked(){
                        let result=(||->Result<Settings,String>{
                            let owner=self.account.profile.as_ref().ok_or("请重新连接账户")?.id;
                            let next=restore(&self.settings,&raw,owner)?;
                            let previous=self.settings.pairs().into_iter().map(|(k,v)|format!("{k}={v}\n")).collect::<String>();
                            model::atomic_write(&model::config_dir().join("settings.before-account-restore.txt"),previous.as_bytes()).map_err(|_|"无法保存本地恢复副本，操作已取消")?;
                            next.try_save().map_err(|_|"保存设置失败，未应用恢复")?;Ok(next)
                        })();
                        match result {Ok(next)=>{self.settings=next;self.account.pending_restore=None;self.account.note="云端设置已恢复，原设置已保存在本地恢复副本中".into();},Err(e)=>self.account.note=e}
                    }
                    if ui.button("取消恢复").clicked(){self.account.pending_restore=None;self.account.note="已取消恢复".into();}
                });
            });
        }
        settings_label(ui,"备份范围");
        settings_card(ui,|ui|{
            settings_hint(ui,"保存外观、页面布局、时钟、歌词、专注和饮水偏好；不包含密码、令牌、邮件、日历、剪贴板或本地文件路径。");
            settings_hint(ui,"仅点击备份时上传。备份使用非公开 Gist：拥有链接的人仍可查看，历史版本由 GitHub 保留。登录令牌仅保存在 Windows 凭据管理器中。");
        });
        settings_label(ui,"更多连接方式");
        settings_card(ui,|ui|{
            for name in ["微信","QQ"]{
                ui.horizontal(|ui|{ui.label(egui::RichText::new(name).strong());ui.add_enabled(false,egui::Button::new("待接入"));});
            }
            settings_hint(ui,"申请开放平台应用并配置授权服务后，即可接入微信、QQ 登录。");
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn account_backup_roundtrip_preserves_device_and_sensitive_settings(){
        let mut source=Settings::default();source.focus_minutes=55;source.skin=model::Skin::Cream;source.visible_pages[2]=false;
        source.display_id="private-monitor".into();source.avoid_apps=vec![("private-app".into(),"C:/private/app.exe".into())];source.ignored_mail_events=vec!["private-mail".into()];
        let raw=serde_json::to_string(&make_backup(&source,42)).unwrap();
        for private in ["private-monitor","private/app","private-mail","read_notifications","clipboard_history"]{assert!(!raw.contains(private));}
        let mut current=Settings::default();current.display_id="local-monitor".into();current.read_notifications=true;
        let restored=restore(&current,&raw,42).unwrap();
        assert_eq!(restored.focus_minutes,55);assert_eq!(restored.skin,model::Skin::Cream);assert!(!restored.visible_pages[2]);
        assert_eq!(restored.display_id,"local-monitor");assert!(restored.read_notifications);
    }
    #[test]
    fn account_restore_rejects_foreign_future_and_injected_backups(){
        let raw=serde_json::to_string(&make_backup(&Settings::default(),42)).unwrap();
        assert!(restore(&Settings::default(),&raw,7).is_err());
        for (key,value) in [("version",json!(99)),("app",json!("other")),("settings",json!({"display_id":"foreign"})),("settings",json!({"skin":"cream\nsound=1"}))]{
            let mut data:Value=serde_json::from_str(&raw).unwrap();data[key]=value;
            assert!(restore(&Settings::default(),&data.to_string(),42).is_err());
        }
        assert!(restore(&Settings::default(),&" ".repeat(LIMIT as usize+1),42).is_err());
    }
    #[test]
    fn account_gist_validation_rejects_public_wrong_owner_and_truncation(){
        let mut gist=json!({"owner":{"id":42},"public":false,"description":DESCRIPTION,"files":{(FILE):{"content":"{}","size":2,"truncated":false}}});
        assert_eq!(checked_content(&gist,42).unwrap(),"{}");assert!(checked_content(&gist,43).is_err());
        gist["public"]=json!(true);assert!(checked_content(&gist,42).is_err());gist["public"]=json!(false);
        gist["files"][FILE]["truncated"]=json!(true);assert!(checked_content(&gist,42).is_err());
    }
}
