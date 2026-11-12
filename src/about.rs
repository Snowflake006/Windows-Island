use crate::{app::{App,Cmd},extras::{settings_card,settings_label},settings_theme::color as settings_color};
use eframe::egui::{self,Color32,RichText};

pub(crate) const PROJECT:&str="https://github.com/Snowflake006/Windows-Island";
pub(crate) const ORIGINAL:&str="https://github.com/Renly1994/xiaotang-daozai";

impl App {
    pub(crate) fn about_settings(&mut self,ui:&mut egui::Ui){
        let ctx=ui.ctx().clone();
        let muted=settings_color(&ctx,Color32::from_gray(175),Color32::from_gray(100));
        ui.add_space(14.0);
        settings_card(ui,|ui|{
            ui.horizontal(|ui|{
                ui.add(egui::Image::new(egui::include_image!("../assets/daozai-logo.png")).fit_to_exact_size(egui::vec2(46.0,46.0)));
                ui.add_space(9.0);
                ui.vertical(|ui|{
                    ui.label(RichText::new("Windows Island").size(22.0).strong());
                    ui.label(RichText::new("桌面状态与效率助手").size(11.5).color(muted));
                });
            });
            ui.add_space(2.0);
            ui.horizontal_wrapped(|ui|{
                egui::Frame::new().fill(settings_color(&ctx,Color32::from_rgb(28,64,102),Color32::from_rgb(229,241,255))).corner_radius(5.0).inner_margin(egui::Margin::symmetric(7,3)).show(ui,|ui|{ui.label(RichText::new(format!("v{}",env!("CARGO_PKG_VERSION"))).size(11.0).color(settings_color(&ctx,Color32::from_rgb(121,188,255),Color32::from_rgb(0,105,210))));});
                ui.label(RichText::new("Windows 10 / 11 · x64 · MIT 开源").size(11.0).color(muted));
            });
            ui.label(RichText::new("基于岛仔 Daozai 二次开发 · 致敬原创").size(10.5).color(muted));
        });
        settings_label(ui,"软件更新");
        settings_card(ui,|ui|{
            ui.label(RichText::new("从 Windows Island 官方发布源获取更新").size(12.0).strong());
            ui.label(RichText::new("Snowflake006 / Windows-Island").size(11.0).color(muted));
            self.updates.ui(ui);
            ui.label(RichText::new("发现新版本后点击「立即更新」，下载并校验后自动重启，保留设置与记录。").size(11.0).color(muted));
        });
        settings_label(ui,"功能一览");
        settings_card(ui,|ui|{
            ui.label(RichText::new("音乐、任务与消息，轻轻放在桌面边缘。").size(12.0));
            egui::CollapsingHeader::new("查看全部功能").id_salt("island-all-features").show(ui,|ui|{
                for (title,detail) in [
                    ("智能体与桌面状态","多智能体运行状态、完成停留、Token / 上下文快照、窗口唤起；空闲待办轮播。"),
                    ("外观与交互","五种皮肤、刘海 / 胶囊、顶部 / 左右停靠、多屏、大小与位置、极简与自动避让；独立拖动徽标和状态组件。"),
                    ("徽标、VPN 与解锁","Windows / 校徽切换；彩色 VPN 时间胶囊；会话解锁问候与面容动画。"),
                    ("音乐与歌词","播放控制、音量与进度、专辑封面、同步歌词、岛上单行歌词与时间偏移。"),
                    ("专注、饮水与待办","番茄计时、休息、饮水目标与提醒；单次 / 每日 / 每周重复任务。"),
                    ("文件与剪贴板","文件拖放、置物架、打开与定位；文字历史、固定与再次复制。"),
                    ("通知、邮箱与日程","系统通知、微信 / QQ 未读、邮件验证码与正文、邮箱整理、月历、日程提醒、ICS / CalDAV / Exchange。"),
                    ("AI 额度与系统提示","多账号额度、余额和重置时间；电量、音量、网络、蓝牙、输入语言与大写锁定；开机启动与本地更新。"),
                ]{ui.label(RichText::new(title).size(12.0).strong());ui.label(RichText::new(detail).size(11.0).color(muted));ui.add_space(4.0);}
            });
            ui.hyperlink_to("完整功能与使用说明",format!("{PROJECT}/blob/main/docs/FEATURES.md"));
        });
        settings_label(ui,"致敬原创");
        settings_card(ui,|ui|{
            ui.label(RichText::new("基于「岛仔 Daozai」二次开发").size(13.0).strong());
            ui.label(RichText::new("本软件基于原作者 Renly1994 的开源作品进行二次开发。致敬原创，感谢原作者与贡献者为桌面体验付出的心血。").size(11.5).color(muted));
            ui.horizontal_wrapped(|ui|{ui.hyperlink_to("原创作者 · Renly1994",ORIGINAL);ui.label(RichText::new("MIT License").size(11.0).color(muted));});
            ui.label(RichText::new("原项目版权声明与第三方许可随软件保留。").size(10.5).color(muted));
        });
        ui.add_space(12.0);
        ui.horizontal_wrapped(|ui|{
            ui.hyperlink_to("项目主页",PROJECT);
            ui.hyperlink_to("反馈问题",format!("{PROJECT}/issues"));
            if ui.small_button("本地数据").clicked(){self.pending.push(Cmd::Open(crate::model::config_dir()));}
        });
        ui.add_space(6.0);
        ui.label(RichText::new("设备图标：Solar Icons · 480 Design · CC BY 4.0").size(10.0).color(muted));
    }
}
