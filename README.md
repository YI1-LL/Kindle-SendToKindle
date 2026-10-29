# SendToKindle v1.5.0 —— Kindle 一键把本地书推到 Kindle 邮箱

在 KUAL 里点一下书，通过 SMTP 把 EPUB/PDF/TXT/DOCX/MOBI/AZW3 作为附件发到你的 `xxx@kindle.com`，
几分钟后自动同步到设备（云端存档）。Kindle 端**不需要 Python**，不模拟网页登录，不碰亚马逊账号。

- 版本：**1.5.0**
- 二进制：`send_to_kindle`（Go 标准库静态编译，CGO_ENABLED=0）
- 平台：ARMv7（armhf）越狱 Kindle + KUAL

---

## 一、使用前提

| 项目 | 要求 |
|---|---|
| 设备 | 已越狱并装好 **KUAL** |
| CPU | **ARMv7**（KPW3/4/5/6、Kindle 10/11/12 代）；`uname -m` 应为 `armv7l` |
| 邮箱 | QQ / 163 / 126 / Gmail 等支持 SMTP 的邮箱，并拿到**授权码** |
| Kindle 邮箱 | 亚马逊「管理我的内容和设备 → 设备」里的 `xxx_12@kindle.com` |
| 网络 | Kindle 已连 Wi-Fi |

> 收不到邮件 90% 是没把发件邮箱加进亚马逊的「已认可的发件人电子邮箱列表」。

## 二、安装（全程 USB，不需要 SSH）

1. USB 连接 → **Internal Storage → extensions**
2. 把整个 `SendToKindle` 文件夹拖进去，结构：

```
extensions/SendToKindle/
├── config.xml          ← KUAL 靠它发现插件，不能少
├── menu.json           ← 首次安装的种子菜单（点 [1] 后会被重写）
├── config.ini          ← 需要你填
├── send_to_kindle      ← 编译产物（也可放 bin/ 下，脚本两种都认）
└── bin/
    ├── scan.sh         ← 扫描书目，生成菜单
    ├── send.sh         ← 发送（网络自检 / 大文件拦截 / 日志截断）
    ├── confirm.sh      ← 大文件二次确认
    ├── cancel.sh       ← 取消大文件
    ├── delete.sh       ← 删除上次发送的本地文件
    ├── unsupported.sh  ← 灰名单提示（cbz/cbr/prc/pdb）
    └── picker.sh       ← 仅 SSH 环境用的备用选书脚本，可忽略
```

> 文件夹名必须是 **`SendToKindle`**（脚本按插件目录自身定位）。

3. 编辑 `config.ini`（**UTF-8 无 BOM + LF**）：

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

- `use_ssl` 现在不参与判断：固定走 465 端口 TLS 直连
- `from` 可省略，默认等于 `user`
- 授权码：QQ 邮箱 → 设置 → 账户 → 开启 POP3/SMTP 服务 → 生成授权码

4. （可选）SSH/kterm 赋权，vfat 下一般不需要：

```sh
chmod +x /mnt/us/extensions/SendToKindle/send_to_kindle
chmod +x /mnt/us/extensions/SendToKindle/bin/*.sh
```

5. 弹出 → 打开 KUAL → **Send to Kindle**

## 三、菜单结构

```
Send to Kindle
├─ [1] 刷新书目 (当前 N 本)                ← 首次必点；点完会闪回主页，正常
├─ [!] 确认发送名片: 书名                  ← 仅当有大文件待确认
├─ [x] 取消发送                           ← 仅当有大文件待确认
├─ [2] 删除上次发送: 书名                  ← 仅当发送成功过
├─ [3] 最近阅读 (最多 10 本)               ← 文件 mtime 与 .sdr mtime 取最大后降序；空则隐藏
├─ [4] 全部书目 (A-Z, N 本)               ← 正常格式，按字母排序
└─ [5] 不支持推送 (cbz/cbr/prc/pdb, N 本)  ← 灰名单，点了只提示，不会发送
```

- `[1]` 点完**要退出 KUAL 再进一次**才能看到新书目（KUAL 只在启动时读 `menu.json`）
- 灰名单子项 `exitmenu: false`，提示画在**屏幕底部两行**，KUAL 留在菜单里，不跳转、不白屏

## 四、发送流程

**小文件（≤ 50 MB）**
点书名 → 屏幕正中 `[ > > ] SENDING...` → 成功 `[ OK ] SENT! / Check your mailbox.` → **原地停留**（不跳转，方便看结果）

**大文件（> 50 MB）**
点书名 → 屏幕 `[ ?? ] > 50MB / Reopen KUAL to confirm` → 回 KUAL 多出两项：

- `[!] 确认发送名片: 书名` → 发送 **HTML 试读名片**（书名 / 作者 / 前 1000 字 / 原文件大小），原书留在本地
- `[x] 取消发送` → 什么都不发，菜单恢复

**失败提示**（`send.log` 里有完整报错）

| 屏幕 | 含义 |
|---|---|
| `[ !! ] NO WIFI / Check connection` | 网络自检失败（ping 与 TCP 465 都不通） |
| `[ !! ] FAILED! / File not found` | 书被删或路径失效 |
| `[ !! ] FAILED! / Error: 535 Auth` | 授权码错/过期/风控 |
| `[ !! ] FAILED! / Error: 550 Mailbox` | 收件邮箱不对 / 白名单没加 |
| `[ !! ] FAILED! / Check send.log` | 其他，看日志 |

## 五、配置自动恢复与备份

- 发送**成功后**把 `config.ini` 备份为 `config.ini.bak`（内容相同不写盘，保护闪存）
- 内容是模板（含 `your_email@qq.com`）时**不备份**
- 启动时：`config.ini` 不存在 → 用 `.bak` 恢复；`config.ini` 又是模板 → 用 `.bak` 覆盖

> 覆盖插件时误把模板 config.ini 拷回去，也会自动找回你的配置。
> 注意 `.bak` 里是**授权码明文**，分享插件前记得删。

## 六、日志

`send.log` 每次写入后检查行数，**超过 500 行**自动截断为最近 200 行并追加 `--- log trimmed ---`。
`scan.log` 记录每次菜单重建的统计。

## 七、命令行（可选，SSH/kterm）

```sh
# 只验证账号密码，不发信
/mnt/us/extensions/SendToKindle/send_to_kindle -test-auth

# 只生成本地 .eml 预览，不联网
/mnt/us/extensions/SendToKindle/send_to_kindle -config ... -file xxx.epub -dry-run

# 手动发送（>50MB 加 --force）
sh /mnt/us/extensions/SendToKindle/bin/send.sh "/mnt/us/documents/xxx.epub" [--force]
```

## 八、限制

- 附件上限 50 MB（亚马逊），超出改为 HTML 名片
- **不支持推送**：`.cbz .cbr .prc .pdb`（列在 `[5]`，点了只提示）
- `.kfx` 完全不列出（亚马逊加密容器，无解）

## 九、常见问题

| 现象 | 解决 |
|---|---|
| KUAL 看不到插件 | 缺 `config.xml`、目录名不对、`menu.json` 不是合法 JSON |
| 点了闪退/白屏 | 脚本被存成 CRLF 或 BOM |
| `[1]` 点完没变化 | 退出 KUAL 再进一次 |
| 邮件发出但亚马逊没收到 | 加白名单；确认 `to` 是 `@kindle.com` 或 `@kindle.cn` |
| `[5]` 里点了没反应 | 灰名单设计如此，只提示不发送 |
| 大文件确认后仍失败 | 看 `send.log`；可能是网络或亚马逊配额 |

## 十、编译

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 \
go build -trimpath -ldflags="-s -w" -o send_to_kindle main.go
```

或推到 GitHub 用 `.github/workflows/build.yml` 出三种架构的包。

## 十一、卸载

```sh
rm -rf /mnt/us/extensions/SendToKindle
```
