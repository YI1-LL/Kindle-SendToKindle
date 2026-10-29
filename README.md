# SendToKindle —— Kindle 一键把本地书推到 Kindle 邮箱

在 KUAL 里点一下书，通过 SMTP 把 EPUB/PDF/TXT/DOCX/MOBI/AZW3 作为邮件附件发到你的 `xxx@kindle.com`，
几分钟后自动同步到设备（等于云端存档）。Kindle 端**不需要 Python**，也不模拟网页登录。

版本：0.1.0（内置二进制为 send_to_kindle 1.2.0，含 `-test-auth` 和 50 MB 降级）

---

## 一、使用前提

| 项目 | 要求 |
|---|---|
| 设备 | 已越狱并装好 **KUAL** 的 Kindle |
| CPU | **ARMv7（armhf）**。KPW3/4/5/6、Kindle 10/11/12 代基本都行；`uname -m` 应为 `armv7l` |
| 邮箱 | 一个支持 SMTP 的邮箱（QQ/163/126/Gmail…），并拿到**授权码**（不是登录密码） |
| Kindle 邮箱 | 亚马逊「管理我的内容和设备 → 设备」里那串 `xxx_12@kindle.com`（国区是 `@kindle.cn`） |
| 网络 | Kindle 要连 Wi-Fi |

> 收不到邮件最常见的原因：**没把发件邮箱加进亚马逊的「已认可的发件人电子邮箱列表」**。
> 亚马逊「管理我的内容和设备 → 首选项 → 个人文档设置」里添加。

## 二、安装（全程 USB，不需要 SSH）

1. USB 连接 Kindle，进 **Internal Storage → extensions**
2. 把整个 `SendToKindle` 文件夹拖进去，最终结构必须是：

```
extensions/SendToKindle/
├── config.xml          ← KUAL 靠它发现插件，不能少
├── menu.json
├── config.ini          ← 需要你填
├── send_to_kindle      ← ARM 静态二进制
└── bin/
    ├── scan.sh
    ├── send.sh
    ├── delete.sh
    └── picker.sh       ← 仅 SSH 环境用的备用选书脚本，可忽略
```

> ⚠️ 文件夹名必须是 **`SendToKindle`**（脚本里写死了 `/mnt/us/extensions/SendToKindle`，改名会失效）。

3. 编辑 `config.ini`（用 VS Code / Notepad++，**UTF-8 无 BOM + LF**）：

```ini
[smtp]
host = smtp.qq.com
port = 465
use_ssl = true
user = 你的邮箱@qq.com
password = 16位授权码

[kindle]
to = 你的名字_12@kindle.com
```

授权码获取：QQ 邮箱网页 → 设置 → 账户 → 开启 POP3/SMTP 服务 → 生成授权码（16 位小写字母）。

4. （可选）SSH/kterm 里赋权，vfat 下一般不需要：

```sh
chmod +x /mnt/us/extensions/SendToKindle/send_to_kindle
chmod +x /mnt/us/extensions/SendToKindle/bin/*.sh
```

5. 弹出设备 → 打开 KUAL → 出现 **Send to Kindle**。

## 三、使用

```
KUAL → Send to Kindle
├─ [1] 刷新书目          ← 第一次必点，扫描 documents，重建菜单
└─ [3] 选书发送 (N 本)   ← 点书名直接发
```

- 点完 `[1]` 会闪一下回主页（正常），**退出 KUAL 再进一次**才能看到书目
- 发送结果会显示在屏幕正中：`SEND OK` / `SENT (TXT ONLY)` / `SEND FAILED`
- 想删本地文件：发送成功后再进 KUAL，会多出 `[2] 删除上次发送: 书名`

### 命令行（可选，SSH/kterm）

```sh
# 只验证账号密码，不发信（10 秒出结果）
/mnt/us/extensions/SendToKindle/send_to_kindle -test-auth

# 只生成本地 .eml 预览，不联网
/mnt/us/extensions/SendToKindle/send_to_kindle -config ... -file xxx.epub -dry-run

# 交互式选书（SSH 用；KUAL 里没有键盘输入）
sh /mnt/us/extensions/SendToKindle/bin/picker.sh
```

## 四、限制

- **附件上限 50 MB**：超过时不会硬发，而是在 `/tmp` 生成一份 `Too_Large_原文件名.txt` 发出去（写明路径和大小），原文件留在本地
- **不支持的格式**：`.kfx`（亚马逊加密容器）无法邮件推送，脚本不会列出
- 推荐 EPUB/PDF/TXT/DOCX；AZW3 可能被亚马逊转换或拒收
- 菜单最多列 150 本（太多会卡），可在 `bin/scan.sh` 里改 `MAX_ITEMS`

## 五、常见问题

| 现象 | 原因 / 解决 |
|---|---|
| KUAL 里看不到插件 | 缺 `config.xml`、目录名不对、或 `menu.json` 不是合法 JSON |
| 点了没反应 / 闪退 | 脚本被保存成 CRLF 或带 BOM；用 VS Code 另存为 **UTF-8 + LF** |
| `config.ini 还是模板` | `user`/`password`/`to` 还是占位符，必须改成自己的 |
| `535 Login fail` | ①授权码错/过期 ②用了登录密码 ③QQ 频率风控（等 10–30 分钟） |
| `550 Mailbox unavailable` | 收件地址不是有效的 Kindle 推送邮箱（去亚马逊后台重新确认） |
| `Exec format error` | 设备不是 ARMv7，需要按自己架构重新交叉编译（`GOARCH=arm GOARM=7` / `arm64`） |
| 邮件发出但亚马逊没收到 | 发件邮箱没加进「已认可的发件人」白名单 |
| 屏幕文字是英文 | Kindle 系统字体没有中文，界面提示统一用 ASCII |

## 六、卸载

```sh
rm -rf /mnt/us/extensions/SendToKindle
```

## 七、隐私说明

- `config.ini` 是**空模板**，不含任何人的邮箱或授权码，需要填自己的
- 程序不联网做任何事，只连接你配置的 SMTP 服务器发信
- 日志只写在插件目录（`send.log` / `scan.log`），不上传
- 源码为纯 Go 标准库 + POSIX sh，可自行审查

## 八、从源码重新编译（可选）

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 \
go build -trimpath -ldflags="-s -w" -o send_to_kindle main.go
```

或把仓库推到 GitHub，用 `.github/workflows/build.yml` 在 Actions 里出三种架构的包。
