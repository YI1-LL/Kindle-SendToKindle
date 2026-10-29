// send_to_kindle —— 把 Kindle 本地电子书通过 SMTP 附件推送到 @kindle.com
//
// v1.3.0：超过 50 MB 的不再硬发，改为生成一份"HTML 试读名片"（书名/作者/试读）推送，
//         原书留在本地，由 KUAL 菜单做二次确认。
//
// 纯 Go 标准库实现，无第三方依赖，交叉编译为 Linux ARM 静态二进制（CGO_ENABLED=0）。
// 用法：
//   ./send_to_kindle -config ./config.ini -file "/mnt/us/documents/foo.epub"
//   ./send_to_kindle -test-auth        # 只验证 SMTP 账号/授权码
//   ./send_to_kindle -file foo.epub -dry-run   # 只生成 .eml 预览，不发信
package main

import (
	"archive/zip"
	"bufio"
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"errors"
	"flag"
	"fmt"
	"html"
	"io"
	"mime"
	"mime/multipart"
	"net"
	"net/smtp"
	"net/textproto"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	appVersion    = "1.5.0"
	maxAttachSize = 50 << 20 // 亚马逊个人文档附件上限 50 MB
	dialTimeout   = 30 * time.Second
	sessionExpire = 15 * time.Minute

	// base64 每行 76 字符 = 57 字节原始数据（57 是 3 的倍数，保证按行切分不破坏编码）
	rawPerLine = 57

	excerptRunes = 1000 // 试读字数
	maxEntryRead = 4 << 20

	// config.ini 自动恢复/备份
	configBackupSuffix = ".bak"                 // config.ini -> config.ini.bak
	templateMarker     = "your_email@qq.com"    // 配置里出现它就说明还是模板
)

// ---------------------------------------------------------------- 配置

type config struct {
	host     string
	port     int
	useSSL   bool
	user     string
	password string
	to       string
	from     string
	insecure bool
	caFile   string
}

// resolveConfig 在读取配置前做自动恢复：
//  1) config.ini 存在但内容是模板（含 your_email@qq.com），且有 config.ini.bak → 用 bak 覆盖
//  2) config.ini 不存在但 config.ini.bak 存在 → 用 bak 恢复
//
// 这样「覆盖插件时误把模板 config.ini 一起拷回去」也能自愈。
func resolveConfig(cfgPath string) {
	backup := cfgPath + configBackupSuffix

	data, err := os.ReadFile(cfgPath)
	if err == nil {
		if strings.Contains(string(data), templateMarker) {
			if _, statErr := os.Stat(backup); statErr == nil {
				if copyErr := copyFile(backup, cfgPath); copyErr == nil {
					fmt.Fprintf(os.Stderr, "♻️  config.ini 是模板，已从 config.ini.bak 恢复\n")
				}
			}
		}
		return
	}

	if os.IsNotExist(err) {
		if _, statErr := os.Stat(backup); statErr == nil {
			if copyErr := copyFile(backup, cfgPath); copyErr == nil {
				fmt.Fprintf(os.Stderr, "♻️  未找到 config.ini，已从 config.ini.bak 恢复\n")
			}
		}
	}
}

// backupConfig 发送成功后备份配置：
//   - 模板配置不备份（避免把 your_email@qq.com 覆盖掉真备份）
//   - 内容与已有 .bak 相同则不写盘（保护闪存）
func backupConfig(cfgPath string) {
	src, err := os.ReadFile(cfgPath)
	if err != nil {
		return
	}
	if strings.Contains(string(src), templateMarker) {
		return
	}
	backup := cfgPath + configBackupSuffix
	if dst, err := os.ReadFile(backup); err == nil && bytes.Equal(src, dst) {
		return
	}
	_ = os.WriteFile(backup, src, 0o600)
}

func copyFile(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, data, 0o600)
}

// loadConfig 解析极简 INI：支持 [section]、key = value、# 和 ; 注释。
// 密码里可以包含 '='，按第一个 '=' 切分。
func loadConfig(cfgPath string) (*config, error) {
	raw, err := os.ReadFile(cfgPath)
	if err != nil {
		return nil, fmt.Errorf("读取配置文件失败: %w", err)
	}

	vals := make(map[string]string)
	section := ""

	for i, line := range strings.Split(string(raw), "\n") {
		line = strings.TrimPrefix(line, "\ufeff") // 兼容 Windows 记事本写入的 BOM
		line = strings.TrimSpace(strings.TrimSuffix(line, "\r"))
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
			continue
		}
		if strings.HasPrefix(line, "[") {
			if !strings.HasSuffix(line, "]") {
				return nil, fmt.Errorf("config.ini 第 %d 行段落格式错误: %q", i+1, line)
			}
			section = strings.ToLower(strings.TrimSpace(line[1 : len(line)-1]))
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			return nil, fmt.Errorf("config.ini 第 %d 行缺少 '=': %q", i+1, line)
		}
		key := strings.ToLower(strings.TrimSpace(k))
		if section != "" {
			key = section + "." + key
		}
		vals[key] = cleanValue(v)
	}

	c := &config{
		host:     vals["smtp.host"],
		user:     vals["smtp.user"],
		password: vals["smtp.password"],
		to:       vals["kindle.to"],
		from:     vals["smtp.from"],
		caFile:   vals["smtp.ca_file"],
	}

	c.useSSL, err = boolValue(vals["smtp.use_ssl"], true)
	if err != nil {
		return nil, fmt.Errorf("smtp.use_ssl 只能填 true/false: %w", err)
	}
	c.insecure, err = boolValue(vals["smtp.insecure_skip_verify"], false)
	if err != nil {
		return nil, fmt.Errorf("smtp.insecure_skip_verify 只能填 true/false: %w", err)
	}

	if p := vals["smtp.port"]; p != "" {
		n, convErr := strconv.Atoi(p)
		if convErr != nil || n <= 0 || n > 65535 {
			return nil, fmt.Errorf("smtp.port 不是合法端口号: %q", p)
		}
		c.port = n
	} else if c.useSSL {
		c.port = 465
	} else {
		c.port = 587
	}

	var missing []string
	for _, kv := range []struct {
		name string
		val  string
	}{
		{"smtp.host", c.host},
		{"smtp.user", c.user},
		{"smtp.password", c.password},
		{"kindle.to", c.to},
	} {
		if strings.TrimSpace(kv.val) == "" {
			missing = append(missing, kv.name)
		}
	}
	if len(missing) > 0 {
		return nil, fmt.Errorf("config.ini 缺少必填项: %s", strings.Join(missing, ", "))
	}

	// 占位符检测：避免把模板原样发出去，从而得到一条看不懂的 535
	isPlaceholder := func(s string) bool {
		s = strings.ToLower(s)
		return strings.HasPrefix(s, "your_") || strings.HasPrefix(s, "yourname") ||
			s == "your_auth_code" || strings.Contains(s, "your_email")
	}
	if isPlaceholder(c.user) || isPlaceholder(c.password) || isPlaceholder(c.to) || isPlaceholder(c.from) {
		return nil, errors.New("config.ini 还是模板：请把 user（你的QQ邮箱）、password（16 位授权码）、to（xxx@kindle.com 或 xxx@kindle.cn）改成自己的值")
	}

	if c.from == "" {
		c.from = c.user
	}
	if !strings.Contains(c.to, "@") {
		return nil, fmt.Errorf("kindle.to 不是合法邮箱: %q", c.to)
	}
	// kindle.com 与 kindle.cn（国区）都是合法的 Kindle 推送邮箱
	if !strings.Contains(strings.ToLower(c.to), "kindle.com") &&
		!strings.Contains(strings.ToLower(c.to), "kindle.cn") {
		fmt.Fprintf(os.Stderr, "⚠️  kindle.to 看起来不是 Kindle 专属邮箱（通常是 xxx@kindle.com 或 xxx@kindle.cn），仍继续发送\n")
	}
	if strings.ContainsAny(c.password, " \t") {
		fmt.Fprintf(os.Stderr, "⚠️  smtp.password 里含空格，QQ/163 的授权码不应有空格，请确认是否复制错了\n")
	}

	return c, nil
}

// cleanValue 去掉复制粘贴时最常见的脏字符：
// 首尾空白/换行、UTF-8 BOM、不间断空格(U+00A0)、零宽空格(U+200B)、全角空格(U+3000)。
func cleanValue(s string) string {
	s = strings.ReplaceAll(s, "\ufeff", "")
	s = strings.ReplaceAll(s, "\u00a0", " ")
	s = strings.ReplaceAll(s, "\u200b", "")
	s = strings.ReplaceAll(s, "\u3000", " ")
	return strings.TrimSpace(s)
}

func boolValue(s string, def bool) (bool, error) {
	s = strings.ToLower(cleanValue(s))
	switch s {
	case "":
		return def, nil
	case "true", "yes", "y", "1", "on":
		return true, nil
	case "false", "no", "n", "0", "off":
		return false, nil
	}
	return def, fmt.Errorf("%q", s)
}

// tlsConfig 生成 TLS 配置；Kindle 若缺根证书可用 insecure_skip_verify 或 ca_file 兜底。
func (c *config) tlsConfig() *tls.Config {
	t := &tls.Config{
		ServerName:         c.host,
		MinVersion:         tls.VersionTLS12,
		InsecureSkipVerify: c.insecure, // 由用户在 config.ini 显式开启
	}
	if c.caFile != "" {
		pool, err := x509.SystemCertPool()
		if err != nil || pool == nil {
			pool = x509.NewCertPool()
		}
		pem, readErr := os.ReadFile(c.caFile)
		switch {
		case readErr != nil:
			fmt.Fprintf(os.Stderr, "⚠️  读取 ca_file 失败(%v)，改用系统证书池\n", readErr)
		case !pool.AppendCertsFromPEM(pem):
			fmt.Fprintf(os.Stderr, "⚠️  ca_file 里没有可用的 PEM 证书\n")
		default:
			t.RootCAs = pool
		}
	}
	return t
}

// ---------------------------------------------------------------- 书名清洗

var titleCleaners = []*regexp.Regexp{
	regexp.MustCompile(`(?i)[-_ ]?cdeKey[_-]?[0-9A-F]*`),
	regexp.MustCompile(`_[0-9A-F]{16,}`),
	regexp.MustCompile(`(?i)\s*\((?:z-library|1lib|z-lib)[^)]*\)`),
	regexp.MustCompile(`(?i)[-_ ](?:z-library|1lib|z-lib)\.?[a-z]*`),
	regexp.MustCompile(`\s*\(\s*etc\.?\s*\)`),
	regexp.MustCompile(`\s*-\s*副本\s*$`),
	regexp.MustCompile(`\s*\(\d+\)\s*$`),
	regexp.MustCompile(`\s{2,}`),
}

// cleanTitle 从文件名里洗掉常见的下载站后缀，只留书名。
func cleanTitle(fileName string) string {
	name := fileName
	if ext := filepath.Ext(name); ext != "" && len(ext) <= 6 {
		name = strings.TrimSuffix(name, ext)
	}
	for _, re := range titleCleaners {
		name = re.ReplaceAllString(name, " ")
	}
	name = strings.Trim(name, " -_·.")
	name = strings.Join(strings.Fields(name), " ")
	if name == "" {
		name = "未命名文档"
	}
	return name
}

// ---------------------------------------------------------------- EPUB 解析

var (
	reRootfile = regexp.MustCompile(`(?i)full-path\s*=\s*"([^"]+)"`)
	reDCTitle  = regexp.MustCompile(`(?is)<dc:title[^>]*>(.*?)</dc:title>`)
	reDCCreat  = regexp.MustCompile(`(?is)<dc:creator[^>]*>(.*?)</dc:creator>`)
	reItemTag  = regexp.MustCompile(`(?is)<item\s[^>]*>`)
	reItemRef  = regexp.MustCompile(`(?is)<itemref\s[^>]*>`)
	reAttr     = regexp.MustCompile(`(?i)([a-zA-Z:_-]+)\s*=\s*"([^"]*)"`)
	reScript   = regexp.MustCompile(`(?is)<script[^>]*>.*?</script>`)
	reStyle    = regexp.MustCompile(`(?is)<style[^>]*>.*?</style>`)
	reTags     = regexp.MustCompile(`(?s)<[^>]*>`)
	reSpaces   = regexp.MustCompile(`\s+`)
)

type epubMeta struct {
	Title   string
	Author  string
	Excerpt string
	OK      bool
}

func readZipEntry(f *zip.File, limit int64) (string, error) {
	rc, err := f.Open()
	if err != nil {
		return "", err
	}
	defer rc.Close()
	b, err := io.ReadAll(io.LimitReader(rc, limit))
	if err != nil {
		return "", err
	}
	return string(b), nil
}

func findZipEntry(zr *zip.ReadCloser, name string) *zip.File {
	name = strings.TrimPrefix(name, "./")
	for _, f := range zr.File {
		if f.Name == name {
			return f
		}
	}
	return nil
}

// htmlToText 去掉标签、脚本、样式，压平空白。
func htmlToText(s string) string {
	s = reScript.ReplaceAllString(s, " ")
	s = reStyle.ReplaceAllString(s, " ")
	s = reTags.ReplaceAllString(s, " ")
	s = html.UnescapeString(s)
	s = reSpaces.ReplaceAllString(s, " ")
	return strings.TrimSpace(s)
}

// parseEPUB 读取 container.xml → .opf → 书名/作者 → 正文第一段试读。
func parseEPUB(srcPath string) epubMeta {
	var meta epubMeta

	zr, err := zip.OpenReader(srcPath)
	if err != nil {
		return meta
	}
	defer zr.Close()

	// 1) META-INF/container.xml → opf 路径
	opfPath := ""
	if cf := findZipEntry(zr, "META-INF/container.xml"); cf != nil {
		if data, err := readZipEntry(cf, 256*1024); err == nil {
			if m := reRootfile.FindStringSubmatch(data); len(m) > 1 {
				opfPath = m[1]
			}
		}
	}
	if opfPath == "" {
		return meta
	}

	opfFile := findZipEntry(zr, opfPath)
	if opfFile == nil {
		return meta
	}
	opf, err := readZipEntry(opfFile, maxEntryRead)
	if err != nil {
		return meta
	}

	// 2) 书名 / 作者
	if m := reDCTitle.FindStringSubmatch(opf); len(m) > 1 {
		meta.Title = strings.Join(strings.Fields(html.UnescapeString(htmlToText(m[1]))), " ")
	}
	if m := reDCCreat.FindStringSubmatch(opf); len(m) > 1 {
		meta.Author = strings.Join(strings.Fields(html.UnescapeString(htmlToText(m[1]))), " ")
	}

	// 3) manifest: id → href；spine: 阅读顺序
	hrefByID := make(map[string]string)
	for _, item := range reItemTag.FindAllString(opf, -1) {
		attrs := attrMap(item)
		id := attrs["id"]
		href := attrs["href"]
		mt := strings.ToLower(attrs["media-type"])
		if id == "" || href == "" {
			continue
		}
		if mt == "" || strings.Contains(mt, "html") || strings.Contains(mt, "xml") {
			hrefByID[id] = href
		}
	}

	var order []string
	for _, ref := range reItemRef.FindAllString(opf, -1) {
		if id := attrMap(ref)["idref"]; id != "" {
			if href, ok := hrefByID[id]; ok {
				order = append(order, href)
			}
		}
	}

	// 4) 按 spine 顺序取第一段有内容的章节
	base := path.Dir(opfPath)
	tryRead := func(href string) string {
		p := href
		if unescaped, err := url.PathUnescape(href); err == nil {
			p = unescaped
		}
		p = path.Join(base, p)
		f := findZipEntry(zr, p)
		if f == nil {
			return ""
		}
		data, err := readZipEntry(f, maxEntryRead)
		if err != nil {
			return ""
		}
		return htmlToText(data)
	}

	for _, href := range order {
		if txt := tryRead(href); len([]rune(txt)) >= 200 {
			meta.Excerpt = truncateRunes(txt, excerptRunes)
			break
		}
	}
	// spine 拿不到就退化成"扫所有 xhtml/html"
	if meta.Excerpt == "" {
		for _, f := range zr.File {
			low := strings.ToLower(f.Name)
			if !strings.HasSuffix(low, ".xhtml") && !strings.HasSuffix(low, ".html") {
				continue
			}
			if strings.Contains(low, "nav") || strings.Contains(low, "toc") || strings.Contains(low, "cover") {
				continue
			}
			data, err := readZipEntry(f, maxEntryRead)
			if err != nil {
				continue
			}
			if txt := htmlToText(data); len([]rune(txt)) >= 200 {
				meta.Excerpt = truncateRunes(txt, excerptRunes)
				break
			}
		}
	}

	meta.OK = meta.Title != "" || meta.Excerpt != ""
	return meta
}

func attrMap(tag string) map[string]string {
	m := make(map[string]string)
	for _, pair := range reAttr.FindAllStringSubmatch(tag, -1) {
		m[strings.ToLower(pair[1])] = pair[2]
	}
	return m
}

// truncateRunes 按字符（不是字节）截断，避免把中文切成半个字。
func truncateRunes(s string, max int) string {
	r := []rune(s)
	if len(r) <= max {
		return s
	}
	return string(r[:max]) + "…"
}

// safeFileName 去掉文件名里的非法字符并限长。
var reBadName = regexp.MustCompile(`[\\/:*?"<>|\x00-\x1f]`)

func safeFileName(s string) string {
	s = reBadName.ReplaceAllString(s, "_")
	s = strings.TrimSpace(s)
	if s == "" {
		s = "book"
	}
	return truncateRunes(s, 80)
}

// ---------------------------------------------------------------- HTML 名片

func formatOf(srcPath string) string {
	ext := strings.ToLower(filepath.Ext(srcPath))
	switch ext {
	case ".epub":
		return "EPUB"
	case ".pdf":
		return "PDF"
	case ".mobi":
		return "MOBI"
	case ".azw3":
		return "AZW3"
	case ".txt":
		return "TXT"
	case ".docx":
		return "DOCX"
	}
	return strings.TrimPrefix(ext, ".")
}

// buildHTMLCard 为 >50MB 的文件生成一份 HTML 试读名片，返回 (路径, 书名, 作者)。
func buildHTMLCard(srcPath string, size int64) (string, string, string, error) {
	fileName := filepath.Base(srcPath)

	var meta epubMeta
	if strings.EqualFold(filepath.Ext(srcPath), ".epub") {
		meta = parseEPUB(srcPath)
	}

	title := strings.TrimSpace(meta.Title)
	if title == "" {
		title = cleanTitle(fileName)
	}
	author := strings.TrimSpace(meta.Author)
	excerpt := strings.TrimSpace(meta.Excerpt)

	outPath := filepath.Join(os.TempDir(), "Too_Large_"+safeFileName(title)+".html")

	esc := html.EscapeString
	authorLine := "未知作者"
	if author != "" {
		authorLine = esc(author)
	}

	var b strings.Builder
	b.WriteString("<!DOCTYPE html>\n<html lang=\"zh-CN\">\n<head>\n<meta charset=\"utf-8\">\n")
	b.WriteString("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n")
	b.WriteString("<title>" + esc("[未推送] "+title) + "</title>\n")
	b.WriteString(`<style>
body{margin:0 auto;padding:1.2em;max-width:34em;line-height:1.75;color:#111;font-family:serif;}
h1{font-size:1.5em;line-height:1.35;margin:.2em 0 .3em;}
.meta{color:#555;font-size:.92em;margin:0 0 1em;}
.warn{color:#b00020;border:2px solid #b00020;border-radius:.35em;padding:.7em .9em;margin:1em 0;font-size:.95em;}
.warn b{display:block;margin-bottom:.25em;}
h2{font-size:1.05em;margin:1.4em 0 .5em;padding-bottom:.2em;border-bottom:1px solid #ccc;}
.excerpt{text-indent:2em;margin:0 0 1em;color:#222;}
.tip{color:#666;font-size:.88em;margin-top:1.6em;border-top:1px dashed #bbb;padding-top:.8em;}
</style>
</head>
<body>
`)
	b.WriteString("<h1>" + esc("[未推送] "+title) + "</h1>\n")
	b.WriteString(fmt.Sprintf("<p class=\"meta\">%s ｜ %s ｜ %s</p>\n", authorLine, esc(formatOf(srcPath)), esc(humanSize(size))))
	b.WriteString("<div class=\"warn\"><b>文件超过 50 MB，邮件通道无法推送原书</b>")
	b.WriteString("这封邮件里只有这张试读名片。请把原书用 USB 拷贝到 Kindle，或用 Calibre 拆分后再推送。</div>\n")
	b.WriteString(fmt.Sprintf("<p class=\"meta\">原文件：%s</p>\n", esc(fileName)))

	if excerpt != "" {
		b.WriteString("<h2>试读</h2>\n")
		b.WriteString("<p class=\"excerpt\">" + esc(excerpt) + "</p>\n")
	} else {
		b.WriteString("<h2>试读</h2>\n")
		b.WriteString("<p class=\"excerpt\">（这个格式没法自动提取正文，只能给你书名和大小。）</p>\n")
	}

	b.WriteString("<p class=\"tip\">由 SendToKindle " + esc(appVersion) + " 自动生成 · 原书仍保存在你的 Kindle 里</p>\n")
	b.WriteString("</body>\n</html>\n")

	if err := os.WriteFile(outPath, []byte(b.String()), 0o644); err != nil {
		return "", "", "", err
	}
	return outPath, title, author, nil
}

// ---------------------------------------------------------------- 邮件构建

// writeMessage 把完整邮件（头部 + 正文 + base64 附件）流式写入 w，内存占用与文件大小无关。
func writeMessage(c *config, w io.Writer, filePath string) error {
	name := filepath.Base(filePath)

	f, err := os.Open(filePath)
	if err != nil {
		return fmt.Errorf("打开文件失败: %w", err)
	}
	defer f.Close()

	st, err := f.Stat()
	if err != nil {
		return fmt.Errorf("读取文件信息失败: %w", err)
	}
	if st.Size() == 0 {
		return errors.New("文件大小为 0，无法发送")
	}
	if st.Size() > maxAttachSize {
		return fmt.Errorf("文件 %.1f MB 超过亚马逊 50 MB 附件上限", float64(st.Size())/(1<<20))
	}

	mw := multipart.NewWriter(w)

	var hdr strings.Builder
	fmt.Fprintf(&hdr, "From: %s\r\n", c.from)
	fmt.Fprintf(&hdr, "To: %s\r\n", c.to)
	fmt.Fprintf(&hdr, "Subject: %s\r\n", encodeSubject(name))
	fmt.Fprintf(&hdr, "Date: %s\r\n", time.Now().Format(time.RFC1123Z))
	hdr.WriteString("MIME-Version: 1.0\r\n")
	fmt.Fprintf(&hdr, "Content-Type: multipart/mixed; boundary=%q\r\n", mw.Boundary())
	hdr.WriteString("\r\n")
	if _, err := io.WriteString(w, hdr.String()); err != nil {
		return fmt.Errorf("写入邮件头失败: %w", err)
	}

	// 正文
	bodyHeader := textproto.MIMEHeader{}
	bodyHeader.Set("Content-Type", "text/plain; charset=UTF-8")
	bodyHeader.Set("Content-Transfer-Encoding", "base64")
	bodyPart, err := mw.CreatePart(bodyHeader)
	if err != nil {
		return fmt.Errorf("创建正文失败: %w", err)
	}
	body := fmt.Sprintf("《%s》已通过 SMTP 推送到 %s。\r\n\r\n大小: %s\r\n时间: %s\r\n发送端: Kindle (%s)\r\n",
		name, c.to, humanSize(st.Size()), time.Now().Format("2006-01-02 15:04:05"), appVersion)
	if err := writeBase64(bodyPart, strings.NewReader(body)); err != nil {
		return fmt.Errorf("编码正文失败: %w", err)
	}

	// 附件
	attHeader := textproto.MIMEHeader{}
	attHeader.Set("Content-Type", contentTypeWithName(name))
	attHeader.Set("Content-Disposition", contentDisposition(name))
	attHeader.Set("Content-Transfer-Encoding", "base64")
	attPart, err := mw.CreatePart(attHeader)
	if err != nil {
		return fmt.Errorf("创建附件失败: %w", err)
	}
	if err := writeBase64(attPart, f); err != nil {
		return fmt.Errorf("编码附件失败: %w", err)
	}

	if err := mw.Close(); err != nil {
		return fmt.Errorf("结束 multipart 失败: %w", err)
	}
	return nil
}

// writeBase64 以 76 列换行的 base64 流式写入 w（附件可达 50 MB，不整块读入内存）。
func writeBase64(w io.Writer, src io.Reader) error {
	bw := bufio.NewWriterSize(w, 64*1024)
	encBuf := make([]byte, base64.StdEncoding.EncodedLen(rawPerLine))

	emit := func(p []byte) error {
		for len(p) > 0 {
			n := rawPerLine
			if len(p) < n {
				n = len(p)
			}
			enc := encBuf[:base64.StdEncoding.EncodedLen(n)]
			base64.StdEncoding.Encode(enc, p[:n])
			if _, err := bw.Write(enc); err != nil {
				return err
			}
			if _, err := bw.WriteString("\r\n"); err != nil {
				return err
			}
			p = p[n:]
		}
		return nil
	}

	buf := make([]byte, rawPerLine*512)
	pending := make([]byte, 0, len(buf)+rawPerLine)

	for {
		n, readErr := io.ReadFull(src, buf)
		if n > 0 {
			pending = append(pending, buf[:n]...)
			full := len(pending) - len(pending)%3 // 只输出 3 的整数倍，剩余留到下一轮
			if full > 0 {
				if err := emit(pending[:full]); err != nil {
					return err
				}
				copy(pending, pending[full:])
				pending = pending[:len(pending)-full]
			}
		}
		if readErr == io.EOF || readErr == io.ErrUnexpectedEOF {
			if len(pending) > 0 {
				if err := emit(pending); err != nil {
					return err
				}
			}
			break
		}
		if readErr != nil {
			return readErr
		}
	}
	return bw.Flush()
}

func isASCII(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] >= 0x80 {
			return false
		}
	}
	return true
}

// encodeSubject 非 ASCII 主题按 RFC 2047 编码，过长时截断。
func encodeSubject(name string) string {
	if isASCII(name) {
		return name
	}
	r := []rune(name)
	if len(r) > 80 {
		name = string(r[:80]) + "..."
	}
	return mime.BEncoding.Encode("UTF-8", name)
}

// asciiFallback 生成只含 ASCII 的备用文件名，兼容不认 RFC 2231 的老客户端。
func asciiFallback(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch {
		case r < 0x20 || r == 0x7f:
			b.WriteByte('_')
		case r < 0x80:
			if r == '"' || r == '\\' {
				b.WriteByte('_')
			} else {
				b.WriteRune(r)
			}
		default:
			b.WriteByte('_')
		}
	}
	out := b.String()
	if strings.Trim(out, "_") == "" {
		out = "attachment"
	}
	return out
}

func quoteName(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '"', '\\':
			b.WriteByte('\\')
			b.WriteByte(s[i])
		case '\r', '\n':
			// 头部注入防护：直接丢弃
		default:
			b.WriteByte(s[i])
		}
	}
	b.WriteByte('"')
	return b.String()
}

// percentEncode 按 RFC 2231 对 UTF-8 字节做百分号编码。
func percentEncode(s string) string {
	const hexDigits = "0123456789ABCDEF"
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		ch := s[i]
		if (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') ||
			strings.IndexByte("!#$&+-.^_`|~", ch) >= 0 {
			b.WriteByte(ch)
			continue
		}
		b.WriteByte('%')
		b.WriteByte(hexDigits[ch>>4])
		b.WriteByte(hexDigits[ch&0x0f])
	}
	return b.String()
}

func contentTypeWithName(name string) string {
	if isASCII(name) {
		return "application/octet-stream; name=" + quoteName(name)
	}
	return "application/octet-stream; name*=UTF-8''" + percentEncode(name)
}

func contentDisposition(name string) string {
	if isASCII(name) {
		return "attachment; filename=" + quoteName(name)
	}
	return "attachment; filename=" + quoteName(asciiFallback(name)) +
		"; filename*=UTF-8''" + percentEncode(name)
}

// ---------------------------------------------------------------- SMTP

func send(c *config, filePath string) error {
	addr := net.JoinHostPort(c.host, strconv.Itoa(c.port))
	dialer := &net.Dialer{Timeout: dialTimeout}

	var (
		conn net.Conn
		err  error
	)
	if c.useSSL {
		conn, err = tls.DialWithDialer(dialer, "tcp", addr, c.tlsConfig())
		if err != nil {
			return fmt.Errorf("TLS 连接 %s 失败: %w", addr, err)
		}
	} else {
		conn, err = dialer.Dial("tcp", addr)
		if err != nil {
			return fmt.Errorf("连接 %s 失败: %w", addr, err)
		}
	}
	defer conn.Close()

	if err := conn.SetDeadline(time.Now().Add(sessionExpire)); err != nil {
		return fmt.Errorf("设置超时失败: %w", err)
	}

	client, err := smtp.NewClient(conn, c.host)
	if err != nil {
		return fmt.Errorf("SMTP 握手失败: %w", err)
	}
	defer client.Close()

	if !c.useSSL {
		if ok, _ := client.Extension("STARTTLS"); ok {
			if err := client.StartTLS(c.tlsConfig()); err != nil {
				return fmt.Errorf("STARTTLS 失败: %w", err)
			}
		}
	}

	if ok, _ := client.Extension("AUTH"); !ok {
		return errors.New("服务器未提供 AUTH 认证，无法登录")
	}

	auth := smtp.PlainAuth("", c.user, c.password, c.host)
	if err := client.Auth(auth); err != nil {
		return fmt.Errorf("SMTP 认证失败: %w", err)
	}

	if err := client.Mail(c.from); err != nil {
		return fmt.Errorf("MAIL FROM 被拒绝: %w", err)
	}
	if err := client.Rcpt(c.to); err != nil {
		return fmt.Errorf("RCPT TO 被拒绝: %w", err)
	}

	wc, err := client.Data()
	if err != nil {
		return fmt.Errorf("DATA 命令被拒绝: %w", err)
	}
	if err := writeMessage(c, wc, filePath); err != nil {
		wc.Close() // 尽力收尾，错误以此前的为准
		return err
	}
	if err := wc.Close(); err != nil {
		return fmt.Errorf("提交邮件内容失败: %w", err)
	}
	if err := client.Quit(); err != nil {
		return fmt.Errorf("QUIT 失败: %w", err)
	}
	return nil
}

// testAuth 只测「连得上 + 账号授权码对不对」，不发信。
func testAuth(c *config) error {
	addr := net.JoinHostPort(c.host, strconv.Itoa(c.port))
	dialer := &net.Dialer{Timeout: dialTimeout}

	var (
		conn net.Conn
		err  error
	)
	if c.useSSL {
		conn, err = tls.DialWithDialer(dialer, "tcp", addr, c.tlsConfig())
		if err != nil {
			return fmt.Errorf("TLS 连接 %s 失败: %w", addr, err)
		}
	} else {
		conn, err = dialer.Dial("tcp", addr)
		if err != nil {
			return fmt.Errorf("连接 %s 失败: %w", addr, err)
		}
	}
	defer conn.Close()

	if err := conn.SetDeadline(time.Now().Add(60 * time.Second)); err != nil {
		return fmt.Errorf("设置超时失败: %w", err)
	}

	client, err := smtp.NewClient(conn, c.host)
	if err != nil {
		return fmt.Errorf("SMTP 握手失败: %w", err)
	}
	defer client.Close()

	if !c.useSSL {
		if ok, _ := client.Extension("STARTTLS"); ok {
			if err := client.StartTLS(c.tlsConfig()); err != nil {
				return fmt.Errorf("STARTTLS 失败: %w", err)
			}
		}
	}

	if err := client.Auth(smtp.PlainAuth("", c.user, c.password, c.host)); err != nil {
		return fmt.Errorf("SMTP 认证失败: %w", err)
	}
	if err := client.Quit(); err != nil {
		return fmt.Errorf("QUIT 失败: %w", err)
	}
	return nil
}

// ---------------------------------------------------------------- 输出

func humanSize(n int64) string {
	const unit = 1024
	if n < unit {
		return fmt.Sprintf("%d B", n)
	}
	div, exp := int64(unit), 0
	for m := n / unit; m >= unit; m /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", float64(n)/float64(div), "KMGT"[exp])
}

// hint 把常见 SMTP 报错翻译成中文排错提示。
func hint(err error) string {
	msg := strings.ToLower(err.Error())
	switch {
	case strings.Contains(msg, "unencrypted connection"):
		return "服务器未启用加密，PlainAuth 拒绝明文发送：请把 use_ssl 设为 true（QQ/163/Gmail 用 465/587）。"
	case strings.Contains(msg, "x509") || strings.Contains(msg, "certificate"):
		return "证书校验失败：Kindle 可能缺根证书。可在 config.ini 设置 insecure_skip_verify = true，或用 ca_file 指定 PEM 证书。"
	case strings.Contains(msg, "unrecognized authentication"), strings.Contains(msg, "504"):
		return "服务器不认 AUTH PLAIN（个别邮箱只开放 LOGIN）。建议改用 QQ/163 的 465 端口，或 Gmail 应用专用密码 + 587。"
	case strings.Contains(msg, "535"), strings.Contains(msg, "login fail"),
		strings.Contains(msg, "authentication failed"), strings.Contains(msg, "530"):
		return "认证失败(535) 常见三种原因：① config.ini 里 user/password 还是模板或写错；" +
			"② 授权码过期（重新在邮箱设置里生成）；③ QQ/163 登录频率风控（等 10–30 分钟再试）。" +
			"先用 -test-auth 单独验证账号。"
	case strings.Contains(msg, "no such host"), strings.Contains(msg, "timeout"),
		strings.Contains(msg, "connection refused"), strings.Contains(msg, "network is unreachable"):
		return "网络不通：确认 Kindle 已连 Wi-Fi，且当前网络没有封掉 465/587 端口。"
	case strings.Contains(msg, "554"), strings.Contains(msg, "550"), strings.Contains(msg, "551"):
		return "服务器拒收：检查 kindle.to 是否正确、发件邮箱是否已加入亚马逊「已认可的发件人」列表。"
	case strings.Contains(msg, "too large") || strings.Contains(msg, "size"):
		return "附件超限：亚马逊约 50 MB，QQ/163 一般 25–50 MB。"
	}
	return ""
}

func fail(format string, args ...interface{}) {
	fmt.Fprintf(os.Stderr, "❌ "+format+"\n", args...)
	os.Exit(1)
}

func main() {
	cfgPath := flag.String("config", "/mnt/us/extensions/SendToKindle/config.ini", "config.ini 路径")
	filePath := flag.String("file", "", "要发送的电子书路径")
	dryRun := flag.Bool("dry-run", false, "只生成本地 .eml 预览文件，不连服务器（调试用）")
	testAuthOnly := flag.Bool("test-auth", false, "只测试 SMTP 账号/授权码，不发信")
	showVer := flag.Bool("version", false, "显示版本")
	flag.Parse()

	if *showVer {
		fmt.Printf("send_to_kindle %s\n", appVersion)
		return
	}

	// 覆盖插件时可能把模板 config.ini 一起拷回来，这里先自动恢复
	resolveConfig(*cfgPath)

	cfg, err := loadConfig(*cfgPath)
	if err != nil {
		fail("%v", err)
	}

	// -test-auth：不碰文件，只验证「网络 + 账号 + 授权码」
	if *testAuthOnly {
		fmt.Printf("🔐 测试 SMTP 认证: %s @ %s:%d (use_ssl=%v, to=%s)\n",
			cfg.user, cfg.host, cfg.port, cfg.useSSL, cfg.to)
		authStart := time.Now()
		if authErr := testAuth(cfg); authErr != nil {
			fmt.Fprintf(os.Stderr, "❌ 认证失败: %v\n", authErr)
			if h := hint(authErr); h != "" {
				fmt.Fprintf(os.Stderr, "💡 %s\n", h)
			}
			os.Exit(2)
		}
		fmt.Printf("✅ 认证通过（%.1fs）：账号和授权码可用，可以发书了\n", time.Since(authStart).Seconds())
		return
	}

	if *filePath == "" {
		fail("缺少 -file 参数。用法: send_to_kindle -config config.ini -file <电子书路径>")
	}

	st, err := os.Stat(*filePath)
	if err != nil {
		fail("找不到文件: %v", err)
	}
	if st.IsDir() {
		fail("%s 是目录，不是电子书文件", *filePath)
	}

	// 超过 50 MB：不硬发，生成 HTML 试读名片（含书名/作者/试读），原书留在本地
	sendPath := *filePath
	isCard := false
	cardTitle := ""
	tmpCard := ""

	if st.Size() > maxAttachSize {
		card, title, author, cardErr := buildHTMLCard(*filePath, st.Size())
		if cardErr != nil {
			fail("文件过大且生成 HTML 名片失败: %v", cardErr)
		}
		tmpCard = card
		sendPath = card
		isCard = true
		cardTitle = title
		fmt.Printf("⚠️  原文件 %s 超过 50 MB 附件上限，改为发送 HTML 试读名片\n", humanSize(st.Size()))
		fmt.Printf("   名片: %s\n", card)
		fmt.Printf("   书名: %s", title)
		if author != "" {
			fmt.Printf("   作者: %s", author)
		}
		fmt.Println()
	}

	cleanup := func() {
		if tmpCard != "" {
			if rmErr := os.Remove(tmpCard); rmErr == nil {
				fmt.Printf("🧹 已清理临时文件: %s\n", tmpCard)
			}
		}
	}

	start := time.Now()

	if *dryRun {
		out := sendPath + ".eml"
		f, createErr := os.Create(out)
		if createErr != nil {
			cleanup()
			fail("创建 %s 失败: %v", out, createErr)
		}
		writeErr := writeMessage(cfg, f, sendPath)
		closeErr := f.Close()
		if writeErr != nil {
			cleanup()
			fail("生成预览失败: %v", writeErr)
		}
		if closeErr != nil {
			cleanup()
			fail("写入预览失败: %v", closeErr)
		}
		fmt.Printf("🧪 dry-run 完成（未发送）: %s\n", out)
		fmt.Printf("   收件人: %s   大小: %s\n", cfg.to, humanSize(st.Size()))
		cleanup()
		return
	}

	if err := send(cfg, sendPath); err != nil {
		fmt.Fprintf(os.Stderr, "❌ 发送失败: %v\n", err)
		if h := hint(err); h != "" {
			fmt.Fprintf(os.Stderr, "💡 %s\n", h)
		}
		cleanup()
		os.Exit(2)
	}

	// 发送成功后才备份配置（模板不备份、内容没变不写盘）
	backupConfig(*cfgPath)

	if isCard {
		fmt.Printf("✅ 已发送大文件 HTML 试读名片: %s -> %s\n", cardTitle, cfg.to)
	} else {
		fmt.Printf("✅ 已发送: %s -> %s\n", filepath.Base(sendPath), cfg.to)
	}
	fmt.Printf("   大小: %s   耗时: %.1fs\n", humanSize(st.Size()), time.Since(start).Seconds())
	if isCard {
		fmt.Println("   （原文件未上传，请用 USB 传输完整版）")
	}
	fmt.Println("   亚马逊处理个人文档通常需要几分钟，可在「管理我的内容和设备」里确认。")
	cleanup()
}
